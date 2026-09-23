//! Google Drive `appDataFolder` as the cross-device `SyncTransport`
//! (DESIGN.md "Cross-device sync"). Lives in the Gmail adapter crate because
//! it rides the same OAuth grant and token cache — one Google account, one
//! refresh token, Gmail and Drive scopes together.
//!
//! The app data folder is hidden from the Drive UI, private to this OAuth
//! client, and per user — so every device signed into the same account with
//! the same client id sees the same files.

use heypigeon_core::domain::AccountId;
use heypigeon_core::ports::{RemoteFile, SyncError, SyncTransport};
use serde::Deserialize;

use crate::GmailProvider;

const DRIVE_API: &str = "https://www.googleapis.com/drive/v3/files";
const DRIVE_UPLOAD_API: &str = "https://www.googleapis.com/upload/drive/v3/files";
const FILE_FIELDS: &str = "id,name,md5Checksum";

#[derive(Deserialize)]
struct WireFileList {
    #[serde(default)]
    files: Vec<WireFile>,
    #[serde(rename = "nextPageToken")]
    next_page_token: Option<String>,
}

#[derive(Deserialize)]
struct WireFile {
    id: String,
    name: String,
    #[serde(rename = "md5Checksum")]
    md5_checksum: Option<String>,
}

impl From<WireFile> for RemoteFile {
    fn from(f: WireFile) -> Self {
        RemoteFile {
            id: f.id,
            name: f.name,
            // md5 is present for every binary-content file we write; an
            // absent one just means "always re-download", never a miss.
            fingerprint: f.md5_checksum.unwrap_or_default(),
        }
    }
}

/// Map a Drive HTTP failure. 403s are the interesting ones: Google uses
/// them both for "this token lacks drive.appdata" (grant predates the
/// scope → re-connect) and "Drive API not enabled in this project" (setup
/// doc step) — both are `Unavailable`, i.e. stop retrying, tell the user.
async fn check(resp: reqwest::Response) -> Result<reqwest::Response, SyncError> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    let body = resp.text().await.unwrap_or_default();
    Err(match status.as_u16() {
        401 => SyncError::AuthExpired,
        403 => SyncError::Unavailable(classify_403(&body)),
        404 => SyncError::NotFound,
        _ => SyncError::Provider(format!("{status}: {body}")),
    })
}

fn classify_403(body: &str) -> String {
    let lower = body.to_lowercase();
    if lower.contains("insufficient") || lower.contains("scope") {
        "the account's Google grant predates the Drive scope — re-connect the account to enable sync".into()
    } else if lower.contains("accessnotconfigured")
        || lower.contains("has not been used")
        || lower.contains("disabled")
    {
        "Google Drive API is not enabled in your OAuth project — see docs/google-oauth-setup.md"
            .into()
    } else {
        format!("403: {body}")
    }
}

fn net(e: reqwest::Error) -> SyncError {
    SyncError::Network(e.to_string())
}

impl GmailProvider {
    async fn drive_token(&self, account_id: &AccountId) -> Result<String, SyncError> {
        self.access_token(account_id).await.map_err(|e| match e {
            heypigeon_core::ports::MailError::AuthExpired => SyncError::AuthExpired,
            other => SyncError::Provider(other.to_string()),
        })
    }
}

impl SyncTransport for GmailProvider {
    async fn list(&self, account_id: &AccountId) -> Result<Vec<RemoteFile>, SyncError> {
        let mut out = Vec::new();
        let mut page_token: Option<String> = None;
        loop {
            let mut url = format!(
                "{DRIVE_API}?spaces=appDataFolder&pageSize=100&fields=nextPageToken,files({FILE_FIELDS})"
            );
            if let Some(t) = &page_token {
                url.push_str("&pageToken=");
                url.push_str(&crate::urlencode(t));
            }
            let token = self.drive_token(account_id).await?;
            let resp = self
                .http
                .get(&url)
                .bearer_auth(token)
                .send()
                .await
                .map_err(net)?;
            let page: WireFileList = check(resp)
                .await?
                .json()
                .await
                .map_err(|e| SyncError::Provider(e.to_string()))?;
            out.extend(page.files.into_iter().map(RemoteFile::from));
            match page.next_page_token {
                Some(t) => page_token = Some(t),
                None => return Ok(out),
            }
        }
    }

    async fn download(&self, account_id: &AccountId, file_id: &str) -> Result<Vec<u8>, SyncError> {
        let token = self.drive_token(account_id).await?;
        let resp = self
            .http
            .get(format!(
                "{DRIVE_API}/{}?alt=media",
                crate::urlencode(file_id)
            ))
            .bearer_auth(token)
            .send()
            .await
            .map_err(net)?;
        Ok(check(resp).await?.bytes().await.map_err(net)?.to_vec())
    }

    async fn upload(
        &self,
        account_id: &AccountId,
        file_id: Option<&str>,
        name: &str,
        bytes: Vec<u8>,
    ) -> Result<RemoteFile, SyncError> {
        let token = self.drive_token(account_id).await?;
        let req = match file_id {
            // Replace content only; name and parent stay.
            Some(id) => self
                .http
                .patch(format!(
                    "{DRIVE_UPLOAD_API}/{}?uploadType=media&fields={FILE_FIELDS}",
                    crate::urlencode(id)
                ))
                .header("Content-Type", "application/json")
                .body(bytes),
            // Create: multipart/related = metadata part (name + the magic
            // appDataFolder parent) + content part.
            None => {
                const B: &str = "hp_drive_3kVq9ZpL0tYw";
                let metadata = serde_json::json!({ "name": name, "parents": ["appDataFolder"] });
                let body = multipart_related(B, &metadata.to_string(), &bytes);
                self.http
                    .post(format!(
                        "{DRIVE_UPLOAD_API}?uploadType=multipart&fields={FILE_FIELDS}"
                    ))
                    .header(
                        "Content-Type",
                        format!("multipart/related; boundary=\"{B}\""),
                    )
                    .body(body)
            }
        };
        let resp = req.bearer_auth(token).send().await.map_err(net)?;
        let file: WireFile = check(resp)
            .await?
            .json()
            .await
            .map_err(|e| SyncError::Provider(e.to_string()))?;
        Ok(file.into())
    }
}

/// Drive's multipart upload body: JSON metadata, then the raw content.
fn multipart_related(boundary: &str, metadata_json: &str, content: &[u8]) -> Vec<u8> {
    let mut body = Vec::with_capacity(content.len() + metadata_json.len() + 200);
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{metadata_json}\r\n--{boundary}\r\nContent-Type: application/json\r\n\r\n")
            .as_bytes(),
    );
    body.extend_from_slice(content);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multipart_body_has_metadata_then_content() {
        let body = multipart_related("B", r#"{"name":"x"}"#, b"{\"v\":1}");
        let s = String::from_utf8(body).unwrap();
        assert!(s.starts_with("--B\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{\"name\":\"x\"}\r\n--B\r\n"));
        assert!(s.contains("\r\n\r\n{\"v\":1}\r\n--B--\r\n"));
    }

    #[test]
    fn forbidden_bodies_are_classified() {
        assert!(classify_403(
            r#"{"error":{"message":"Request had insufficient authentication scopes."}}"#
        )
        .contains("re-connect"));
        assert!(classify_403(r#"{"error":{"status":"PERMISSION_DENIED","message":"Google Drive API has not been used in project 1 before or it is disabled."}}"#).contains("not enabled"));
        assert!(classify_403("something else").starts_with("403:"));
    }

    #[test]
    fn wire_file_without_md5_has_empty_fingerprint() {
        let f: WireFile = serde_json::from_str(r#"{"id":"1","name":"state-a.json"}"#).unwrap();
        let r: RemoteFile = f.into();
        assert_eq!(r.fingerprint, "");
        let f: WireFile =
            serde_json::from_str(r#"{"id":"1","name":"n","md5Checksum":"abc"}"#).unwrap();
        assert_eq!(RemoteFile::from(f).fingerprint, "abc");
    }
}
