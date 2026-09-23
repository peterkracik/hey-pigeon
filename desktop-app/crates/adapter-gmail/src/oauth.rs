//! OAuth 2 PKCE loopback flow (native-app flow).
//! Security properties (DESIGN.md): PKCE S256 (intercepted codes are useless
//! without the verifier), random `state` (CSRF), listener binds 127.0.0.1,
//! accepts exactly one request, then shuts down.

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
    pub client_secret: String,
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

/// Run the full authorization flow. `open_url` is called once with the
/// consent URL (the app decides how to open a browser — port boundary:
/// this crate never touches the OS shell).
pub async fn authorize(
    client: &ClientConfig,
    open_url: impl FnOnce(&str),
) -> Result<TokenSet, OauthError> {
    let verifier = random_token();
    let challenge = b64url(&Sha256::digest(verifier.as_bytes()));
    let state = random_token();

    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let redirect_uri = format!("http://127.0.0.1:{port}");

    let auth_url = url::Url::parse_with_params(
        AUTH_ENDPOINT,
        &[
            ("response_type", "code"),
            ("client_id", &client.client_id),
            ("redirect_uri", &redirect_uri),
            ("scope", SCOPE),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", &state),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ],
    )
    .expect("static url");
    open_url(auth_url.as_str());

    let code = tokio::time::timeout(AUTHORIZE_TIMEOUT, wait_for_code(listener, &state))
        .await
        .map_err(|_| OauthError::Timeout)??;

    let resp = reqwest::Client::new()
        .post(TOKEN_ENDPOINT)
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", &code),
            ("client_id", &client.client_id),
            ("client_secret", &client.client_secret),
            ("redirect_uri", &redirect_uri),
            ("code_verifier", &verifier),
        ])
        .send()
        .await?;
    parse_token_response(resp).await
}

/// Exchange a refresh token for a fresh access token.
pub async fn refresh(client: &ClientConfig, refresh_token: &str) -> Result<TokenSet, OauthError> {
    let resp = reqwest::Client::new()
        .post(TOKEN_ENDPOINT)
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("client_id", &client.client_id),
            ("client_secret", &client.client_secret),
        ])
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
    let url = url::Url::parse(&format!("http://127.0.0.1{path}"))
        .map_err(|e| OauthError::Authorization(e.to_string()))?;
    let get = |k: &str| {
        url.query_pairs()
            .find(|(key, _)| key == k)
            .map(|(_, v)| v.into_owned())
    };

    let result = match (get("code"), get("state"), get("error")) {
        (_, _, Some(e)) => Err(OauthError::Authorization(e)),
        (_, Some(s), _) if s != expected_state => {
            Err(OauthError::Authorization("state mismatch".to_string()))
        }
        (Some(code), Some(_), _) => Ok(code),
        _ => Err(OauthError::Authorization(
            "missing code or state".to_string(),
        )),
    };

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
