//! SQLite adapter: implements `Store`.
//! Single connection behind a mutex, WAL mode, migration-only schema
//! (user_version pragma). The DB is a cache — worst case is drop + re-sync.
// ponytail: one global connection lock; a dedicated writer thread + read pool
// only if profiling ever shows contention (M1 is one account, tiny writes).

use std::path::Path;
use std::sync::Mutex;

use heypigeon_core::domain::*;
use heypigeon_core::ports::{Store, StoreError};
use rusqlite::{params, Connection, OptionalExtension};

const MIGRATIONS: &[&str] = &[
    // v1 — M1 scope only. labels/attachments/FTS arrive with their milestones.
    "
    CREATE TABLE accounts (
        id           TEXT PRIMARY KEY,
        email        TEXT NOT NULL,
        display_name TEXT NOT NULL,
        color        TEXT NOT NULL,
        history_id   TEXT
    );
    CREATE TABLE threads (
        id           TEXT PRIMARY KEY,
        account_id   TEXT NOT NULL REFERENCES accounts(id),
        subject      TEXT NOT NULL,
        snippet      TEXT NOT NULL,
        last_msg_at  INTEGER NOT NULL,
        is_read      INTEGER NOT NULL,
        is_inbox     INTEGER NOT NULL,
        is_archived  INTEGER NOT NULL,
        msg_count    INTEGER NOT NULL,
        from_summary TEXT NOT NULL
    );
    CREATE INDEX idx_threads_list ON threads (is_inbox, is_archived, last_msg_at DESC);
    CREATE TABLE messages (
        id         TEXT PRIMARY KEY,
        thread_id  TEXT NOT NULL,
        account_id TEXT NOT NULL REFERENCES accounts(id),
        from_addr  TEXT NOT NULL,
        to_addrs   TEXT NOT NULL,
        date       INTEGER NOT NULL,
        snippet    TEXT NOT NULL,
        body_html  TEXT,
        body_text  TEXT,
        label_ids  TEXT NOT NULL,
        is_read    INTEGER NOT NULL
    );
    CREATE INDEX idx_messages_thread ON messages (thread_id, date);
    CREATE TABLE outbox (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id TEXT NOT NULL REFERENCES accounts(id),
        mutation   TEXT NOT NULL,
        attempts   INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
    );
    ",
    // v2 — latest-sender address for avatar lookups; heals via backfill upserts.
    "ALTER TABLE threads ADD COLUMN last_from_addr TEXT NOT NULL DEFAULT '';",
];

pub struct SqliteStore {
    conn: Mutex<Connection>,
}

fn err(e: impl std::fmt::Display) -> StoreError {
    StoreError(e.to_string())
}

impl SqliteStore {
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        let conn = Connection::open(path).map_err(err)?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Self, StoreError> {
        let conn = Connection::open_in_memory().map_err(err)?;
        Self::init(conn)
    }

    fn init(conn: Connection) -> Result<Self, StoreError> {
        conn.pragma_update(None, "journal_mode", "WAL").map_err(err)?;
        conn.pragma_update(None, "foreign_keys", "ON").map_err(err)?;
        let version: i64 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(err)?;
        for (i, migration) in MIGRATIONS.iter().enumerate().skip(version as usize) {
            conn.execute_batch(migration).map_err(err)?;
            conn.pragma_update(None, "user_version", i as i64 + 1)
                .map_err(err)?;
        }
        Ok(Self { conn: Mutex::new(conn) })
    }

    fn with<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, StoreError> {
        let conn = self.conn.lock().map_err(|_| StoreError("lock poisoned".into()))?;
        f(&conn).map_err(err)
    }

    /// Remove an account and everything belonging to it (used when the dev
    /// fake account is replaced by a real one).
    pub fn delete_account(&self, account_id: &str) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute("DELETE FROM outbox WHERE account_id = ?1", params![account_id])?;
            c.execute("DELETE FROM messages WHERE account_id = ?1", params![account_id])?;
            c.execute("DELETE FROM threads WHERE account_id = ?1", params![account_id])?;
            c.execute("DELETE FROM accounts WHERE id = ?1", params![account_id])?;
            Ok(())
        })
    }
}

fn row_to_thread(r: &rusqlite::Row<'_>) -> rusqlite::Result<Thread> {
    Ok(Thread {
        id: r.get(0)?,
        account_id: r.get(1)?,
        subject: r.get(2)?,
        snippet: r.get(3)?,
        last_msg_at: r.get(4)?,
        is_read: r.get(5)?,
        is_inbox: r.get(6)?,
        is_archived: r.get(7)?,
        msg_count: r.get(8)?,
        from_summary: r.get(9)?,
        last_from_addr: r.get(10)?,
    })
}

const THREAD_COLS: &str =
    "id, account_id, subject, snippet, last_msg_at, is_read, is_inbox, is_archived, msg_count, from_summary, last_from_addr";

impl Store for SqliteStore {
    fn upsert_account(&self, a: &Account) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "INSERT INTO accounts (id, email, display_name, color, history_id)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(id) DO UPDATE SET
                   email = excluded.email, display_name = excluded.display_name,
                   color = excluded.color",
                params![a.id, a.email, a.display_name, a.color, a.history_id],
            )
            .map(|_| ())
        })
    }

    fn list_accounts(&self) -> Result<Vec<Account>, StoreError> {
        self.with(|c| {
            let mut stmt =
                c.prepare("SELECT id, email, display_name, color, history_id FROM accounts ORDER BY id")?;
            let rows = stmt.query_map([], |r| {
                Ok(Account {
                    id: r.get(0)?,
                    email: r.get(1)?,
                    display_name: r.get(2)?,
                    color: r.get(3)?,
                    history_id: r.get(4)?,
                })
            })?;
            rows.collect()
        })
    }

    fn set_history_id(&self, account_id: &AccountId, history_id: &str) -> Result<(), StoreError> {
        let n = self.with(|c| {
            c.execute(
                "UPDATE accounts SET history_id = ?2 WHERE id = ?1",
                params![account_id, history_id],
            )
        })?;
        if n == 0 {
            return Err(StoreError(format!("unknown account {account_id}")));
        }
        Ok(())
    }

    fn upsert_thread(&self, t: &Thread) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                &format!(
                    "INSERT INTO threads ({THREAD_COLS})
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                     ON CONFLICT(id) DO UPDATE SET
                       subject = excluded.subject, snippet = excluded.snippet,
                       last_msg_at = excluded.last_msg_at, is_read = excluded.is_read,
                       is_inbox = excluded.is_inbox, is_archived = excluded.is_archived,
                       msg_count = excluded.msg_count, from_summary = excluded.from_summary,
                       last_from_addr = excluded.last_from_addr"
                ),
                params![
                    t.id, t.account_id, t.subject, t.snippet, t.last_msg_at,
                    t.is_read, t.is_inbox, t.is_archived, t.msg_count, t.from_summary,
                    t.last_from_addr
                ],
            )
            .map(|_| ())
        })
    }

    fn upsert_message(&self, m: &Message) -> Result<(), StoreError> {
        let to_addrs = serde_json::to_string(&m.to_addrs).map_err(err)?;
        let label_ids = serde_json::to_string(&m.label_ids).map_err(err)?;
        self.with(|c| {
            c.execute(
                "INSERT INTO messages
                   (id, thread_id, account_id, from_addr, to_addrs, date, snippet,
                    body_html, body_text, label_ids, is_read)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                 ON CONFLICT(id) DO UPDATE SET
                   snippet = excluded.snippet, body_html = excluded.body_html,
                   body_text = excluded.body_text, label_ids = excluded.label_ids,
                   is_read = excluded.is_read",
                params![
                    m.id, m.thread_id, m.account_id, m.from_addr, to_addrs, m.date,
                    m.snippet, m.body_html, m.body_text, label_ids, m.is_read
                ],
            )
            .map(|_| ())
        })
    }

    fn list_threads(
        &self,
        account_id: Option<&AccountId>,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<Thread>, StoreError> {
        self.with(|c| {
            // Keyset pagination — never OFFSET (DESIGN.md).
            let mut stmt = c.prepare(&format!(
                "SELECT {THREAD_COLS} FROM threads
                 WHERE is_inbox = 1 AND is_archived = 0
                   AND (?1 IS NULL OR account_id = ?1)
                   AND (?2 IS NULL OR last_msg_at < ?2)
                 ORDER BY last_msg_at DESC
                 LIMIT ?3"
            ))?;
            let rows = stmt.query_map(params![account_id, before, limit], row_to_thread)?;
            rows.collect()
        })
    }

    fn get_thread(&self, thread_id: &ThreadId) -> Result<Option<Thread>, StoreError> {
        self.with(|c| {
            c.query_row(
                &format!("SELECT {THREAD_COLS} FROM threads WHERE id = ?1"),
                params![thread_id],
                row_to_thread,
            )
            .optional()
        })
    }

    fn list_messages(&self, thread_id: &ThreadId) -> Result<Vec<Message>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT id, thread_id, account_id, from_addr, to_addrs, date, snippet,
                        body_html, body_text, label_ids, is_read
                 FROM messages WHERE thread_id = ?1 ORDER BY date",
            )?;
            let rows = stmt.query_map(params![thread_id], |r| {
                let to_addrs: String = r.get(4)?;
                let label_ids: String = r.get(9)?;
                Ok(Message {
                    id: r.get(0)?,
                    thread_id: r.get(1)?,
                    account_id: r.get(2)?,
                    from_addr: r.get(3)?,
                    to_addrs: serde_json::from_str(&to_addrs).unwrap_or_default(),
                    date: r.get(5)?,
                    snippet: r.get(6)?,
                    body_html: r.get(7)?,
                    body_text: r.get(8)?,
                    label_ids: serde_json::from_str(&label_ids).unwrap_or_default(),
                    is_read: r.get(10)?,
                })
            })?;
            rows.collect()
        })
    }

    fn apply_local(&self, mutation: &Mutation) -> Result<(), StoreError> {
        let (sql, thread_id) = match mutation {
            Mutation::Archive { thread_id } => (
                "UPDATE threads SET is_archived = 1, is_inbox = 0 WHERE id = ?1".to_string(),
                thread_id,
            ),
            Mutation::MarkRead { thread_id, read } => (
                format!(
                    "UPDATE threads SET is_read = {} WHERE id = ?1",
                    if *read { 1 } else { 0 }
                ),
                thread_id,
            ),
            Mutation::Trash { thread_id } => (
                "UPDATE threads SET is_inbox = 0 WHERE id = ?1".to_string(),
                thread_id,
            ),
            // Nothing changes locally for outgoing mail (no Sent view in M1).
            Mutation::Send { .. } => return Ok(()),
        };
        let n = self.with(|c| c.execute(&sql, params![thread_id]))?;
        if n == 0 {
            return Err(StoreError(format!("unknown thread {thread_id}")));
        }
        Ok(())
    }

    fn outbox_push(&self, account_id: &AccountId, mutation: &Mutation) -> Result<(), StoreError> {
        let payload = serde_json::to_string(mutation).map_err(err)?;
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.with(|c| {
            c.execute(
                "INSERT INTO outbox (account_id, mutation, attempts, created_at)
                 VALUES (?1, ?2, 0, ?3)",
                params![account_id, payload, now_ms],
            )
            .map(|_| ())
        })
    }

    fn outbox_list(&self, limit: u32) -> Result<Vec<OutboxItem>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT id, account_id, mutation, attempts, created_at
                 FROM outbox ORDER BY id LIMIT ?1",
            )?;
            let rows = stmt.query_map(params![limit], |r| {
                let payload: String = r.get(2)?;
                Ok(OutboxItem {
                    id: r.get(0)?,
                    account_id: r.get(1)?,
                    mutation: serde_json::from_str(&payload).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            2,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    attempts: r.get(3)?,
                    created_at: r.get(4)?,
                })
            })?;
            rows.collect()
        })
    }

    fn outbox_delete(&self, id: i64) -> Result<(), StoreError> {
        self.with(|c| c.execute("DELETE FROM outbox WHERE id = ?1", params![id]).map(|_| ()))
    }

    fn outbox_bump_attempts(&self, id: i64) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "UPDATE outbox SET attempts = attempts + 1 WHERE id = ?1",
                params![id],
            )
            .map(|_| ())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use heypigeon_core::fakes::{sample_account, FakeProvider};
    use heypigeon_core::{outbox, sync};

    fn store() -> SqliteStore {
        let s = SqliteStore::open_in_memory().unwrap();
        s.upsert_account(&sample_account("a1")).unwrap();
        s
    }

    #[tokio::test]
    async fn backfill_end_to_end_against_sqlite() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 25, 10);

        let n = sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();

        assert_eq!(n, 25);
        assert_eq!(store.list_accounts().unwrap()[0].history_id.as_deref(), Some("hist-1"));
        let threads = store.list_threads(None, None, 100).unwrap();
        assert_eq!(threads.len(), 25);
        assert!(threads.windows(2).all(|w| w[0].last_msg_at >= w[1].last_msg_at));

        // keyset pagination: second page strictly older, no overlap
        let page1 = store.list_threads(None, None, 10).unwrap();
        let page2 = store
            .list_threads(None, Some(page1.last().unwrap().last_msg_at), 10)
            .unwrap();
        assert_eq!(page2.len(), 10);
        assert!(page2[0].last_msg_at < page1.last().unwrap().last_msg_at);
    }

    #[tokio::test]
    async fn messages_round_trip() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();

        let t = &store.list_threads(None, None, 1).unwrap()[0];
        let msgs = store.list_messages(&t.id).unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].thread_id, t.id);
        assert!(msgs[0].body_text.is_some());
        assert_eq!(msgs[0].label_ids, vec!["INBOX".to_string()]);
    }

    #[tokio::test]
    async fn optimistic_archive_with_outbox_drain() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();
        let id = store.list_threads(None, None, 1).unwrap()[0].id.clone();

        outbox::enqueue(&store, &"a1".to_string(), Mutation::Archive { thread_id: id.clone() }).unwrap();

        // local view updated instantly; thread gone from inbox list
        assert!(store.get_thread(&id).unwrap().unwrap().is_archived);
        assert!(!store.list_threads(None, None, 10).unwrap().iter().any(|t| t.id == id));

        let (applied, failed) = outbox::drain(&provider, &store, 10).await.unwrap();
        assert_eq!((applied, failed), (1, 0));
        assert!(store.outbox_list(10).unwrap().is_empty());
    }

    #[test]
    fn migrations_are_idempotent_across_reopen() {
        let dir = std::env::temp_dir().join(format!("heypigeon-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("test.db");
        let _ = std::fs::remove_file(&path);
        {
            let s = SqliteStore::open(&path).unwrap();
            s.upsert_account(&sample_account("a1")).unwrap();
        }
        {
            let s = SqliteStore::open(&path).unwrap(); // reopen: migrations skip
            assert_eq!(s.list_accounts().unwrap().len(), 1);
        }
        let _ = std::fs::remove_file(&path);
    }
}
