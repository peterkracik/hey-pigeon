//! OAuth 2 PKCE flow (native-app flow), in two layers:
//!
//! - [`AuthRequest`] is the shell-neutral part: build the consent URL for a
//!   given redirect URI, then validate the callback and exchange the code.
//!   The iOS shell drives it with `ASWebAuthenticationSession` and a
//!   reversed-client-id custom scheme (see [`ios_redirect_uri`]).
//! - [`authorize`] is the desktop loopback flow on top of it: listener binds
//!   127.0.0.1, accepts exactly one request, then shuts down.
//!
//! Security properties (DESIGN.md): PKCE S256 (intercepted codes are useless
//! without the verifier) and a random `state` (CSRF) in both layers.

use base64::Engine;
use rand::RngCore;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const AUTH_ENDPOINT: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";
// drive.appdata = the hidden per-app Drive folder used for cross-device sync
// (DESIGN.md). Grants issued before it was added lack it; the Drive adapter
// reports that as `SyncError::Unavailable` until the account is re-connected.
pub const SCOPE: &str = "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/contacts.other.readonly https://www.googleapis.com/auth/drive.appdata";

#[derive(Debug, thiserror::Error)]
pub enum OauthError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("http: {0}")]
    Http(#[from] reqwest::Error),
    #[error("token endpoint error: {0}")]
    Token(String),
    #[error("authorization failed: {0}")]
    Authorization(String),
    #[error("authorization timed out — the consent tab was never completed")]
    Timeout,
}

// Abandoned consent tabs must not hang the app: give up after this long.
const AUTHORIZE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(300);

#[derive(Debug, Clone, Deserialize)]
pub struct ClientConfig {
    pub client_id: String,
    /// "Desktop app" clients carry a (not actually secret) secret that the
    /// token endpoint insists on; "iOS" clients have none at all.
    #[serde(default)]
    pub client_secret: Option<String>,
}

/// The redirect URI Google requires for an "iOS" OAuth client: the client
/// id reversed into a custom URL scheme. The app registers that scheme in
/// its Info.plist and `ASWebAuthenticationSession` hands the callback back.
pub fn ios_redirect_uri(client_id: &str) -> String {
    let mut parts: Vec<&str> = client_id.split('.').collect();
    parts.reverse();
    format!("{}:/oauthredirect", parts.join("."))
}

/// Tokens as returned by Google. Refresh token goes to the SecretStore;
/// access token stays in memory only.
#[derive(Debug, Clone, Deserialize)]
pub struct TokenSet {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    pub expires_in: u64,
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn random_token() -> String {
    let mut buf = [0u8; 32];
    rand::rng().fill_bytes(&mut buf);
    b64url(&buf)
}

/// A consent request in flight: the consent URL to open, plus the PKCE
/// verifier and `state` needed to finish it. Shell-neutral — it never opens
/// a browser or listens on a socket; the caller owns the redirect.
#[derive(Debug)]
pub struct AuthRequest {
    client: ClientConfig,
    verifier: String,
    state: String,
    redirect_uri: String,
    url: String,
}

impl AuthRequest {
    /// Build the consent URL for `redirect_uri` (a loopback address on
    /// desktop, [`ios_redirect_uri`] on iOS).
    ///
    /// `login_hint` pre-selects a Google account on the consent screen — set
    /// when re-connecting a known account so the user is not asked to pick
    /// one (and is less likely to pick the wrong one). Google treats it as a
    /// hint only; the caller still has to check which account came back.
    pub fn begin(client: &ClientConfig, login_hint: Option<&str>, redirect_uri: &str) -> Self {
        let verifier = random_token();
        let challenge = b64url(&Sha256::digest(verifier.as_bytes()));
        let state = random_token();

        let mut params: Vec<(&str, &str)> = vec![
            ("response_type", "code"),
            ("client_id", &client.client_id),
            ("redirect_uri", redirect_uri),
            ("scope", SCOPE),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", &state),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ];
        if let Some(hint) = login_hint {
            params.push(("login_hint", hint));
        }
        let url = url::Url::parse_with_params(AUTH_ENDPOINT, &params).expect("static url");
        Self {
            client: client.clone(),
            verifier,
            state,
            redirect_uri: redirect_uri.to_string(),
            url: url.into(),
        }
    }

    /// The consent URL to open in a browser / auth session.
    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn redirect_uri(&self) -> &str {
        &self.redirect_uri
    }

    /// Finish with the full callback URL the redirect delivered
    /// (`<redirect_uri>?code=…&state=…`): validates `state`, then exchanges
    /// the code. Consumes the request — a code is single-use and so is the
    /// verifier.
    pub async fn finish(self, callback_url: &str) -> Result<TokenSet, OauthError> {
        let code = extract_code(callback_url, &self.state)?;
        self.exchange(&code).await
    }

    /// Exchange an already-validated authorization code for tokens.
    async fn exchange(self, code: &str) -> Result<TokenSet, OauthError> {
        let mut form: Vec<(&str, &str)> = vec![
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", &self.client.client_id),
            ("redirect_uri", &self.redirect_uri),
            ("code_verifier", &self.verifier),
        ];
        if let Some(secret) = &self.client.client_secret {
            form.push(("client_secret", secret));
        }
        let resp = reqwest::Client::new()
            .post(TOKEN_ENDPOINT)
            .form(&form)
            .send()
            .await?;
        parse_token_response(resp).await
    }
}

/// Pull `code` out of a callback URL, checking `state` first. Shared by the
/// loopback listener and the mobile custom-scheme path.
fn extract_code(callback_url: &str, expected_state: &str) -> Result<String, OauthError> {
    let url =
        url::Url::parse(callback_url).map_err(|e| OauthError::Authorization(e.to_string()))?;
    let get = |k: &str| {
        url.query_pairs()
            .find(|(key, _)| key == k)
            .map(|(_, v)| v.into_owned())
    };
    match (get("code"), get("state"), get("error")) {
        (_, _, Some(e)) => Err(OauthError::Authorization(e)),
        (_, Some(s), _) if s != expected_state => {
            Err(OauthError::Authorization("state mismatch".to_string()))
        }
        (Some(code), Some(_), _) => Ok(code),
        _ => Err(OauthError::Authorization(
            "missing code or state".to_string(),
        )),
    }
}

/// Run the full desktop authorization flow over a loopback redirect.
/// `open_url` is called once with the consent URL (the app decides how to
/// open a browser — port boundary: this crate never touches the OS shell).
/// See [`AuthRequest::begin`] for `login_hint`.
pub async fn authorize(
    client: &ClientConfig,
    login_hint: Option<&str>,
    open_url: impl FnOnce(&str),
) -> Result<TokenSet, OauthError> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let redirect_uri = format!("http://127.0.0.1:{port}");

    let request = AuthRequest::begin(client, login_hint, &redirect_uri);
    open_url(request.url());

    let code = tokio::time::timeout(AUTHORIZE_TIMEOUT, wait_for_code(listener, &request.state))
        .await
        .map_err(|_| OauthError::Timeout)??;
    request.exchange(&code).await
}

/// Exchange a refresh token for a fresh access token.
///
/// Error meaning matters to callers: `Token` is Google rejecting the grant
/// (revoked, expired, password changed — `invalid_grant`), which only a
/// fresh consent flow fixes; `Http`/`Io` are transport failures (offline)
/// and say nothing about whether the account is still connected.
pub async fn refresh(client: &ClientConfig, refresh_token: &str) -> Result<TokenSet, OauthError> {
    let mut form: Vec<(&str, &str)> = vec![
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
        ("client_id", &client.client_id),
    ];
    if let Some(secret) = &client.client_secret {
        form.push(("client_secret", secret));
    }
    let resp = reqwest::Client::new()
        .post(TOKEN_ENDPOINT)
        .form(&form)
        .send()
        .await?;
    parse_token_response(resp).await
}

async fn parse_token_response(resp: reqwest::Response) -> Result<TokenSet, OauthError> {
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        // Google error bodies are safe to log (no tokens on failure).
        return Err(OauthError::Token(body));
    }
    Ok(resp.json::<TokenSet>().await?)
}

/// Accept exactly one loopback request, validate `state`, extract `code`.
async fn wait_for_code(listener: TcpListener, expected_state: &str) -> Result<String, OauthError> {
    let (mut stream, _) = listener.accept().await?;
    let mut buf = vec![0u8; 8192];
    let n = stream.read(&mut buf).await?;
    let request = String::from_utf8_lossy(&buf[..n]);

    // "GET /?code=…&state=… HTTP/1.1"
    let path = request
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .unwrap_or("/");
    let result = extract_code(&format!("http://127.0.0.1{path}"), expected_state);

    let (status, msg) = match &result {
        Ok(_) => (
            "200 OK",
            "Signed in. You can close this tab and return to Hey Pigeon.",
        ),
        Err(_) => (
            "400 Bad Request",
            "Authorization failed. Return to Hey Pigeon and retry.",
        ),
    };
    let body = format!(
        "<!DOCTYPE html><html><body style=\"font-family:sans-serif;padding:40px\"><h2>{msg}</h2></body></html>"
    );
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_is_s256_of_verifier() {
        // RFC 7636 appendix B test vector
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        let challenge = b64url(&Sha256::digest(verifier.as_bytes()));
        assert_eq!(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    fn client() -> ClientConfig {
        ClientConfig {
            client_id: "123-abc.apps.googleusercontent.com".to_string(),
            client_secret: None,
        }
    }

    #[test]
    fn ios_redirect_uri_is_reversed_client_id_scheme() {
        assert_eq!(
            ios_redirect_uri("123-abc.apps.googleusercontent.com"),
            "com.googleusercontent.apps.123-abc:/oauthredirect"
        );
    }

    #[test]
    fn auth_request_url_carries_pkce_state_and_redirect() {
        let redirect = ios_redirect_uri(&client().client_id);
        let req = AuthRequest::begin(&client(), Some("me@example.com"), &redirect);
        let url = url::Url::parse(req.url()).unwrap();
        let q: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(url.host_str(), Some("accounts.google.com"));
        assert_eq!(q["redirect_uri"], redirect);
        assert_eq!(q["state"], req.state);
        assert_eq!(q["code_challenge_method"], "S256");
        assert_eq!(
            q["code_challenge"],
            b64url(&Sha256::digest(req.verifier.as_bytes()))
        );
        assert_eq!(q["login_hint"], "me@example.com");
        assert_eq!(q["access_type"], "offline");
    }

    #[test]
    fn client_secret_is_optional_in_config_json() {
        let c: ClientConfig = serde_json::from_str(r#"{"client_id":"x"}"#).unwrap();
        assert_eq!(c.client_secret, None);
        let c: ClientConfig =
            serde_json::from_str(r#"{"client_id":"x","client_secret":"s"}"#).unwrap();
        assert_eq!(c.client_secret.as_deref(), Some("s"));
    }

    #[test]
    fn extract_code_validates_state_and_errors() {
        let base = "com.googleusercontent.apps.123-abc:/oauthredirect";
        assert_eq!(
            extract_code(&format!("{base}?code=abc&state=st"), "st").unwrap(),
            "abc"
        );
        assert!(extract_code(&format!("{base}?code=abc&state=WRONG"), "st").is_err());
        assert!(extract_code(&format!("{base}?error=access_denied&state=st"), "st").is_err());
        assert!(extract_code(&format!("{base}?state=st"), "st").is_err());
    }

    #[tokio::test]
    async fn finish_rejects_state_mismatch_before_any_network() {
        let req = AuthRequest::begin(&client(), None, "http://127.0.0.1:1");
        let err = req
            .finish("http://127.0.0.1:1/?code=abc&state=WRONG")
            .await
            .unwrap_err();
        assert!(matches!(err, OauthError::Authorization(_)), "{err}");
    }

    #[tokio::test]
    async fn loopback_extracts_code_and_validates_state() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        let client = tokio::spawn(async move {
            use tokio::io::AsyncWriteExt;
            let mut s = tokio::net::TcpStream::connect(("127.0.0.1", port))
                .await
                .unwrap();
            s.write_all(b"GET /?code=abc123&state=st HTTP/1.1\r\nHost: x\r\n\r\n")
                .await
                .unwrap();
            let mut out = Vec::new();
            let _ = s.read_to_end(&mut out).await;
            String::from_utf8_lossy(&out).to_string()
        });

        let code = wait_for_code(listener, "st").await.unwrap();
        assert_eq!(code, "abc123");
        let resp = client.await.unwrap();
        assert!(resp.starts_with("HTTP/1.1 200"));
    }

    #[tokio::test]
    async fn loopback_rejects_state_mismatch() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            use tokio::io::AsyncWriteExt;
            let mut s = tokio::net::TcpStream::connect(("127.0.0.1", port))
                .await
                .unwrap();
            s.write_all(b"GET /?code=abc&state=WRONG HTTP/1.1\r\n\r\n")
                .await
                .unwrap();
        });
        assert!(wait_for_code(listener, "st").await.is_err());
    }
}
