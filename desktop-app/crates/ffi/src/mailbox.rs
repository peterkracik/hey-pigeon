//! Mailbox operations beyond the thread list: managing the account's Gmail
//! labels, searching the whole mailbox at Gmail (the local index only
//! knows the mail already synced), and the addresses it may send from.
//! All of them go to the network and none goes through the outbox: each
//! either worked or reports why not.

use std::sync::Arc;

use heypigeon_core::domain::{AccountId, Thread};
use heypigeon_core::ports::{MailError, MailProvider, Store};

use crate::engine::Engine;
use crate::types::*;

/// Most threads one remote search returns (one page of `threads.list`).
const REMOTE_SEARCH_MAX: u32 = 100;

#[uniffi::export(async_runtime = "tokio")]
impl Engine {
    /// Create a Gmail label on this account. It is in `list_labels` when
    /// this returns; apply it to mail with `Mutation::ModifyLabel`.
    pub async fn create_label(
        &self,
        account_id: String,
        name: String,
    ) -> Result<MailLabel, EngineError> {
        let name = label_name(&name)?;
        let created = {
            let provider = self.provider.read().await;
            provider.create_label(&account_id, &name).await
        };
        let label = created.map_err(|e| self.mail_error(&account_id, e))?;
        self.store.upsert_label(&label)?;
        self.notify_threads_updated();
        Ok(label.into())
    }

    /// Rename a Gmail label. Mail carrying it keeps it (labels go by id).
    pub async fn rename_label(
        &self,
        account_id: String,
        label_id: String,
        new_name: String,
    ) -> Result<(), EngineError> {
        let new_name = label_name(&new_name)?;
        let renamed = {
            let provider = self.provider.read().await;
            provider
                .update_label(&account_id, &label_id, &new_name)
                .await
        };
        renamed.map_err(|e| self.mail_error(&account_id, e))?;
        self.store.rename_label(&account_id, &label_id, &new_name)?;
        self.notify_threads_updated();
        Ok(())
    }

    /// Delete a Gmail label: it comes off every thread that carried it
    /// (the mail itself stays).
    pub async fn delete_label(
        &self,
        account_id: String,
        label_id: String,
    ) -> Result<(), EngineError> {
        let deleted = {
            let provider = self.provider.read().await;
            provider.delete_label(&account_id, &label_id).await
        };
        deleted.map_err(|e| self.mail_error(&account_id, e))?;
        self.store.delete_label(&account_id, &label_id)?;
        self.notify_threads_updated();
        Ok(())
    }

    /// Search the mailbox at Gmail, with Gmail's own query syntax
    /// (`from:`, `has:attachment`, `older_than:`…): the answer for mail
    /// the local index does not hold yet — older than what has been
    /// synced so far. `account_id` None searches every connected account.
    ///
    /// The threads found that the store lacks are fetched (headers and
    /// preview only, never bodies) and stored, so the rows returned open
    /// like any other. Newest first, at most `limit` (capped at 100).
    /// With several accounts, one that fails is left out; the error is
    /// returned only when none answered.
    pub async fn search_remote(
        self: Arc<Self>,
        query: String,
        account_id: Option<String>,
        limit: u32,
    ) -> Result<Vec<MailThread>, EngineError> {
        let query = query.trim().to_string();
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let limit = limit.clamp(1, REMOTE_SEARCH_MAX);
        let accounts: Vec<AccountId> = match account_id {
            Some(id) => vec![id],
            None => {
                let disconnected = self.disconnected_accounts();
                self.store
                    .list_accounts()?
                    .into_iter()
                    .map(|a| a.id)
                    .filter(|id| !disconnected.contains(id))
                    .collect()
            }
        };
        let searches = accounts.iter().map(|account| {
            let engine = Arc::clone(&self);
            let (account, query) = (account.clone(), query.clone());
            async move {
                let found = engine.search_account(&account, &query, limit).await;
                found.map_err(|e| engine.mail_error(&account, e))
            }
        });
        let mut rows: Vec<Thread> = Vec::new();
        let mut first_error = None;
        let mut answered = false;
        for result in futures::future::join_all(searches).await {
            match result {
                Ok(found) => {
                    answered = true;
                    rows.extend(found);
                }
                Err(e) => {
                    log::warn!("remote search: {e}");
                    first_error.get_or_insert(e);
                }
            }
        }
        if let (false, Some(e)) = (answered, first_error) {
            return Err(e);
        }
        rows.sort_by(|a, b| b.last_msg_at.cmp(&a.last_msg_at));
        rows.truncate(limit as usize);
        Ok(rows.into_iter().map(Into::into).collect())
    }

    /// The addresses this account may send from: its own, and the "Send
    /// mail as" aliases verified in Gmail's settings. Pass one as
    /// `from_addr` on `Mutation::Send` / `SaveDraft`. Asked from Gmail
    /// once per launch, then answered from memory.
    pub async fn list_send_as(
        &self,
        account_id: String,
    ) -> Result<Vec<SendAsAddress>, EngineError> {
        let listed = {
            let provider = self.provider.read().await;
            provider.list_send_as(&account_id).await
        };
        Ok(listed
            .map_err(|e| self.mail_error(&account_id, e))?
            .into_iter()
            .map(Into::into)
            .collect())
    }
}

// Internals — not exported.
impl Engine {
    /// A provider error as the shell sees it; a rejected grant also marks
    /// the account disconnected.
    fn mail_error(&self, account_id: &AccountId, e: MailError) -> EngineError {
        if matches!(e, MailError::AuthExpired) {
            self.mark_disconnected(account_id);
        }
        e.into()
    }

    /// One account's matches, as stored rows in Gmail's order.
    async fn search_account(
        &self,
        account_id: &AccountId,
        query: &str,
        limit: u32,
    ) -> Result<Vec<Thread>, MailError> {
        let store_err = |e: heypigeon_core::ports::StoreError| MailError::Provider(e.to_string());
        let provider = self.provider.read().await;
        let ids = provider.search_thread_ids(account_id, query, limit).await?;
        let mut missing = Vec::new();
        for id in &ids {
            if self.store.get_thread(id).map_err(store_err)?.is_none() {
                missing.push(id.clone());
            }
        }
        if !missing.is_empty() {
            let fetched = provider.fetch_thread_metadata(account_id, &missing).await?;
            self.store.upsert_page(&fetched).map_err(store_err)?;
        }
        let mut rows = Vec::with_capacity(ids.len());
        for id in &ids {
            if let Some(t) = self.store.get_thread(id).map_err(store_err)? {
                rows.push(t);
            }
        }
        Ok(rows)
    }
}

/// A label name as Gmail takes it: trimmed, one line, not empty.
fn label_name(name: &str) -> Result<String, EngineError> {
    let name = name.trim();
    if name.is_empty() || name.contains(['\n', '\r']) {
        return Err(EngineError::Invalid("a label needs a name".into()));
    }
    Ok(name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open(tag: &str) -> (Arc<Engine>, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "heypigeon-ffi-mailbox-{tag}-{}-{}",
            std::process::id(),
            heypigeon_core::domain::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let e = Engine::open(
            dir.to_string_lossy().into_owned(),
            OauthClient {
                client_id: "123-abc.apps.googleusercontent.com".to_string(),
                client_secret: None,
            },
        )
        .unwrap();
        (e, dir)
    }

    #[test]
    fn label_names_are_trimmed_and_never_empty() {
        assert_eq!(label_name("  Receipts ").unwrap(), "Receipts");
        assert!(matches!(label_name("   "), Err(EngineError::Invalid(_))));
        assert!(matches!(label_name("a\nb"), Err(EngineError::Invalid(_))));
    }

    /// What needs no network answers without one: an empty query finds
    /// nothing, a nameless label is refused before Gmail is asked, and a
    /// search with no account to ask is empty, not an error.
    #[tokio::test]
    async fn nothing_to_ask_gmail_means_no_request() {
        let (e, dir) = open("offline");
        assert!(Arc::clone(&e)
            .search_remote("   ".into(), None, 20)
            .await
            .unwrap()
            .is_empty());
        assert!(Arc::clone(&e)
            .search_remote("invoice".into(), None, 20)
            .await
            .unwrap()
            .is_empty());
        assert!(matches!(
            e.create_label("a@x.com".into(), " ".into()).await,
            Err(EngineError::Invalid(_))
        ));
        // An account without a stored grant: the call reports it and the
        // account shows as disconnected, as any other call would.
        assert!(matches!(
            e.create_label("a@x.com".into(), "Receipts".into()).await,
            Err(EngineError::AuthExpired(_))
        ));
        assert!(matches!(
            Arc::clone(&e)
                .search_remote("invoice".into(), Some("a@x.com".into()), 20)
                .await,
            Err(EngineError::AuthExpired(_))
        ));
        assert!(e.list_labels().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
