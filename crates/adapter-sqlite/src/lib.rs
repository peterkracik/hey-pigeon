//! SQLite adapter: implements `Store`.
//! Single connection behind a mutex, WAL mode, migration-only schema
//! (user_version pragma). The DB is a cache — worst case is drop + re-sync.
// ponytail: one global connection lock; a dedicated writer thread + read pool
// only if profiling ever shows contention (M1 is one account, tiny writes).

use std::path::Path;
use std::sync::Mutex;

use heypigeon_core::domain::*;
use heypigeon_core::ports::{Store, StoreError};
use heypigeon_core::search::{SearchQuery, SNIPPET_END, SNIPPET_START};
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
    // v3 — account profile photo (Google userinfo picture).
    "ALTER TABLE accounts ADD COLUMN avatar_url TEXT;",
    // v4 — per-account signature.
    "ALTER TABLE accounts ADD COLUMN signature TEXT NOT NULL DEFAULT '';",
    // v5 — FTS5 search index (DESIGN.md Search). External-content over a view
    // (contentless tables can't serve snippet()); triggers on `messages` keep
    // it in sync, 'rebuild' backfills existing rows. Subject lives on threads,
    // so the view joins; sync always upserts the thread before its messages.
    // Body falls back to the message snippet so metadata-tier mail is still
    // findable before its body is fetched.
    // Constraints:
    // - `messages` has a TEXT PK ⇒ implicit rowid, and the FTS index is
    //   keyed on it. VACUUM may renumber implicit rowids — if a VACUUM is
    //   ever added, it must be followed by
    //   INSERT INTO messages_fts(messages_fts) VALUES('rebuild')
    //   or the index silently maps to the wrong messages.
    // - The AU/AD triggers' 'delete' rows read the *current* thread subject;
    //   for external-content FTS5 a 'delete' whose values differ from what
    //   was indexed silently corrupts the index (phantom/missing hits). Fine
    //   while thread subjects never change after indexing (Gmail subjects
    //   are immutable in practice); reindex the thread's messages if subject
    //   edits ever become real.
    "
    CREATE VIEW messages_fts_content AS
      SELECT m.rowid AS rowid,
             COALESCE((SELECT subject FROM threads t WHERE t.id = m.thread_id), '') AS subject,
             m.from_addr AS from_addr,
             m.to_addrs AS to_addrs,
             COALESCE(m.body_text, m.snippet, '') AS body_text
      FROM messages m;
    CREATE VIRTUAL TABLE messages_fts USING fts5(
        subject, from_addr, to_addrs, body_text,
        content='messages_fts_content',
        tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(rowid, subject, from_addr, to_addrs, body_text)
        VALUES (new.rowid,
                COALESCE((SELECT subject FROM threads WHERE id = new.thread_id), ''),
                new.from_addr, new.to_addrs,
                COALESCE(new.body_text, new.snippet, ''));
    END;
    CREATE TRIGGER messages_fts_au AFTER UPDATE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, subject, from_addr, to_addrs, body_text)
        VALUES ('delete', old.rowid,
                COALESCE((SELECT subject FROM threads WHERE id = old.thread_id), ''),
                old.from_addr, old.to_addrs,
                COALESCE(old.body_text, old.snippet, ''));
        INSERT INTO messages_fts(rowid, subject, from_addr, to_addrs, body_text)
        VALUES (new.rowid,
                COALESCE((SELECT subject FROM threads WHERE id = new.thread_id), ''),
                new.from_addr, new.to_addrs,
                COALESCE(new.body_text, new.snippet, ''));
    END;
    CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, subject, from_addr, to_addrs, body_text)
        VALUES ('delete', old.rowid,
                COALESCE((SELECT subject FROM threads WHERE id = old.thread_id), ''),
                old.from_addr, old.to_addrs,
                COALESCE(old.body_text, old.snippet, ''));
    END;
    INSERT INTO messages_fts(messages_fts) VALUES ('rebuild');
    ",
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
        Self::init_to(conn, MIGRATIONS.len())
    }

    /// Run migrations up to `target` (count, not index). Split from `init`
    /// so tests can build a DB at an older schema version and prove the real
    /// upgrade path over pre-existing data.
    fn init_to(conn: Connection, target: usize) -> Result<Self, StoreError> {
        conn.pragma_update(None, "journal_mode", "WAL").map_err(err)?;
        conn.pragma_update(None, "foreign_keys", "ON").map_err(err)?;
        let version: i64 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(err)?;
        for (i, migration) in MIGRATIONS.iter().enumerate().take(target).skip(version as usize) {
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

/// `THREAD_COLS` with a table qualifier (joins in search).
fn thread_cols(prefix: &str) -> String {
    THREAD_COLS
        .split(", ")
        .map(|c| format!("{prefix}{c}"))
        .collect::<Vec<_>>()
        .join(", ")
}

impl Store for SqliteStore {
    fn upsert_account(&self, a: &Account) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "INSERT INTO accounts (id, email, display_name, color, history_id, avatar_url, signature)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(id) DO UPDATE SET
                   email = excluded.email, display_name = excluded.display_name,
                   color = excluded.color, avatar_url = excluded.avatar_url,
                   signature = excluded.signature",
                params![a.id, a.email, a.display_name, a.color, a.history_id, a.avatar_url, a.signature],
            )
            .map(|_| ())
        })
    }

    fn list_accounts(&self) -> Result<Vec<Account>, StoreError> {
        self.with(|c| {
            let mut stmt =
                c.prepare("SELECT id, email, display_name, color, history_id, avatar_url, signature FROM accounts ORDER BY id")?;
            let rows = stmt.query_map([], |r| {
                Ok(Account {
                    id: r.get(0)?,
                    email: r.get(1)?,
                    display_name: r.get(2)?,
                    color: r.get(3)?,
                    history_id: r.get(4)?,
                    avatar_url: r.get(5)?,
                    signature: r.get(6)?,
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
                   snippet = excluded.snippet,
                   -- bodies fetch lazily; a metadata-tier re-upsert (backfill,
                   -- delta thread refetch) must not wipe them
                   body_html = COALESCE(excluded.body_html, body_html),
                   body_text = COALESCE(excluded.body_text, body_text),
                   label_ids = excluded.label_ids,
                   is_read = excluded.is_read",
                params![
                    m.id, m.thread_id, m.account_id, m.from_addr, to_addrs, m.date,
                    m.snippet, m.body_html, m.body_text, label_ids, m.is_read
                ],
            )
            .map(|_| ())
        })
    }

    fn delete_message(&self, message_id: &MessageId) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute("DELETE FROM messages WHERE id = ?1", params![message_id]).map(|_| ())
        })
    }

    fn delete_thread(&self, thread_id: &ThreadId) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute("DELETE FROM messages WHERE thread_id = ?1", params![thread_id])?;
            c.execute("DELETE FROM threads WHERE id = ?1", params![thread_id]).map(|_| ())
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

    /// Ranked local search. With FTS terms: bm25 with column weights
    /// (subject > from > to > body), best message per thread, blended with
    /// recency (age penalty per day — newer mail wins ties). Operators-only
    /// queries fall back to a plain filtered thread scan, newest first.
    fn search(&self, q: &SearchQuery, limit: u32) -> Result<Vec<SearchResult>, StoreError> {
        if q.is_empty() {
            return Ok(Vec::new());
        }
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.with(|c| {
            if let Some(fts) = &q.fts_match {
                // bm25()/snippet() must run in a direct full-text query, so
                // a MATERIALIZED CTE (flattening it back into the join would
                // break that context) scores each matching message; the outer
                // query joins, groups per thread, and keeps the best message.
                // GROUP BY + single min() aggregate: SQLite guarantees bare
                // columns (f.rowid in the snippet subquery) come from the
                // min-bm25 row.
                // Work is bounded: the CTE keeps only the top-?10 rows by
                // bm25 (cheap — no re-tokenization), and snippet() (expensive)
                // runs per surviving row via a rowid-constrained MATCH, never
                // over the whole match set. The cap trades exact recency
                // blending on huge result sets for bounded per-keystroke cost.
                let mut stmt = c.prepare(&format!(
                    "WITH f AS MATERIALIZED (
                        SELECT rowid,
                               bm25(messages_fts, 8.0, 4.0, 2.0, 1.0) AS score
                        FROM messages_fts WHERE messages_fts MATCH ?1
                        ORDER BY score LIMIT ?10)
                     SELECT {},
                            (SELECT snippet(messages_fts, -1, ?2, ?3, '…', 12)
                             FROM messages_fts
                             WHERE messages_fts MATCH ?1 AND rowid = f.rowid) AS snip,
                            min(f.score)
                              + ((?4 - t.last_msg_at) / 86400000.0) * 0.05 AS rank
                     FROM f
                     JOIN messages m ON m.rowid = f.rowid
                     JOIN threads t ON t.id = m.thread_id
                     WHERE (?5 IS NULL OR instr(lower(m.from_addr), ?5) > 0)
                       AND (?6 IS NULL OR instr(lower(m.to_addrs), ?6) > 0)
                       AND (?7 = 0 OR t.is_read = 0)
                       AND (?8 IS NULL OR instr(lower(t.account_id), ?8) > 0)
                     GROUP BY t.id
                     ORDER BY rank
                     LIMIT ?9",
                    thread_cols("t.")
                ))?;
                let candidate_cap = (limit as i64).saturating_mul(10).max(200);
                let rows = stmt.query_map(
                    params![
                        fts,
                        SNIPPET_START.to_string(),
                        SNIPPET_END.to_string(),
                        now_ms,
                        q.from_contains,
                        q.to_contains,
                        q.unread_only,
                        q.account_contains,
                        limit,
                        candidate_cap
                    ],
                    |r| {
                        Ok(SearchResult {
                            thread: row_to_thread(r)?,
                            snippet: r.get(11)?,
                        })
                    },
                )?;
                rows.collect()
            } else {
                let mut stmt = c.prepare(&format!(
                    "SELECT {} FROM threads t
                     WHERE (?1 = 0 OR t.is_read = 0)
                       AND (?2 IS NULL OR instr(lower(t.account_id), ?2) > 0)
                       AND (?3 IS NULL OR EXISTS (
                             SELECT 1 FROM messages m WHERE m.thread_id = t.id
                               AND instr(lower(m.from_addr), ?3) > 0))
                       AND (?4 IS NULL OR EXISTS (
                             SELECT 1 FROM messages m WHERE m.thread_id = t.id
                               AND instr(lower(m.to_addrs), ?4) > 0))
                     ORDER BY t.last_msg_at DESC
                     LIMIT ?5",
                    thread_cols("t.")
                ))?;
                let rows = stmt.query_map(
                    params![
                        q.unread_only,
                        q.account_contains,
                        q.from_contains,
                        q.to_contains,
                        limit
                    ],
                    |r| {
                        let thread = row_to_thread(r)?;
                        let snippet = thread.snippet.clone();
                        Ok(SearchResult { thread, snippet })
                    },
                )?;
                rows.collect()
            }
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

    #[tokio::test]
    async fn metadata_reupsert_preserves_fetched_bodies() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 1, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();
        let t = store.list_threads(None, None, 1).unwrap()[0].clone();
        let mut m = store.list_messages(&t.id).unwrap()[0].clone();
        assert!(m.body_text.is_some(), "fixture has a body");

        // Metadata-tier refetch of the same message carries no bodies.
        m.body_html = None;
        m.body_text = None;
        store.upsert_message(&m).unwrap();

        let after = store.list_messages(&t.id).unwrap()[0].clone();
        assert!(after.body_text.is_some(), "body survives metadata re-upsert");
    }

    // ---------------------------------------------------------------- search

    fn seed_thread(
        s: &SqliteStore,
        id: &str,
        subject: &str,
        from: &str,
        body: &str,
        last_msg_at: i64,
        is_read: bool,
    ) {
        s.upsert_thread(&Thread {
            id: id.to_string(),
            account_id: "a1".to_string(),
            subject: subject.to_string(),
            snippet: body.chars().take(40).collect(),
            last_msg_at,
            is_read,
            is_inbox: true,
            is_archived: false,
            msg_count: 1,
            from_summary: from.to_string(),
            last_from_addr: from.to_string(),
        })
        .unwrap();
        s.upsert_message(&Message {
            id: format!("{id}-m1"),
            thread_id: id.to_string(),
            account_id: "a1".to_string(),
            from_addr: from.to_string(),
            to_addrs: vec!["me@heypigeon.app".to_string()],
            date: last_msg_at,
            snippet: body.chars().take(40).collect(),
            body_html: None,
            body_text: Some(body.to_string()),
            label_ids: vec!["INBOX".to_string()],
            is_read,
        })
        .unwrap();
    }

    fn search(s: &SqliteStore, q: &str) -> Vec<SearchResult> {
        s.search(&heypigeon_core::search::parse(q), 50).unwrap()
    }

    #[test]
    fn search_basic_match_with_snippet() {
        let s = store();
        seed_thread(&s, "t1", "Quarterly report", "priya@x.com", "numbers attached", 1000, false);
        seed_thread(&s, "t2", "Lunch plans", "sam@x.com", "pizza on friday", 2000, false);

        let hits = search(&s, "quarterly");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].thread.id, "t1");
        // snippet() highlight uses the private-use markers, not HTML
        assert!(hits[0].snippet.contains(SNIPPET_START));
        assert!(hits[0].snippet.contains(SNIPPET_END));
        assert!(search(&s, "nonexistentterm").is_empty());
    }

    #[test]
    fn search_prefix_on_last_term() {
        let s = store();
        seed_thread(&s, "t1", "Quarterly report", "priya@x.com", "numbers attached", 1000, false);

        // typing "quart…" mid-word already matches (search-as-you-type)
        assert_eq!(search(&s, "quart").len(), 1);
        // but only the LAST term is a prefix — earlier terms match whole words
        assert!(search(&s, "quart nothing").is_empty());
        assert_eq!(search(&s, "report numb").len(), 1);
    }

    #[test]
    fn search_is_unread_filter() {
        let s = store();
        seed_thread(&s, "t1", "Budget review", "priya@x.com", "q3 budget", 1000, true);
        seed_thread(&s, "t2", "Budget draft", "sam@x.com", "first pass", 2000, false);

        let hits = search(&s, "is:unread budget");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].thread.id, "t2");
        // operators-only query works too (no FTS terms)
        let hits = search(&s, "is:unread");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].thread.id, "t2");
    }

    #[test]
    fn search_from_filter() {
        let s = store();
        seed_thread(&s, "t1", "Budget review", "priya@x.com", "q3 budget", 1000, false);
        seed_thread(&s, "t2", "Budget draft", "sam@x.com", "first pass", 2000, false);

        let hits = search(&s, "from:priya budget");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].thread.id, "t1");
        // case-insensitive, works without FTS terms as well
        let hits = search(&s, "from:PRIYA");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].thread.id, "t1");
    }

    #[test]
    fn search_ranking_subject_beats_body_and_recency_breaks_ties() {
        let s = store();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        // "invoice" only in the body vs in the subject — subject wins even
        // though the body-hit thread is slightly newer.
        seed_thread(&s, "t1", "Invoice overdue", "a@x.com", "see attachment", now - 60_000, false);
        seed_thread(&s, "t2", "Hello", "b@x.com", "the invoice is attached here", now, false);
        // identical text, different age — newer first
        seed_thread(&s, "t3", "Standup notes", "c@x.com", "same text", now - 86_400_000 * 30, false);
        seed_thread(&s, "t4", "Standup notes", "d@x.com", "same text", now, false);
        // filler so bm25's idf term is positive (with a 4-doc corpus where
        // half the docs match, idf is 0 and every score ties at 0)
        for i in 0..4 {
            seed_thread(&s, &format!("f{i}"), "Misc chatter", "z@x.com", "nothing relevant", now - 1_000_000, false);
        }

        let hits = search(&s, "invoice");
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].thread.id, "t1", "subject match ranks above body match");

        let hits = search(&s, "standup");
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].thread.id, "t4", "equal relevance → newer wins");
    }

    #[test]
    fn search_diacritics_fold_both_ways() {
        let s = store();
        seed_thread(&s, "t1", "Péter birthday", "peter@x.com", "cake at five", 1000, false);
        seed_thread(&s, "t2", "Peter standup", "peter@x.com", "notes", 2000, false);

        // remove_diacritics 2: Péter ≈ Peter in both directions
        assert_eq!(search(&s, "peter").len(), 2);
        assert_eq!(search(&s, "péter").len(), 2);
    }

    #[test]
    fn search_index_follows_message_updates_and_deletes() {
        let s = store();
        seed_thread(&s, "t1", "Hello", "a@x.com", "placeholder", 1000, false);
        // lazy body fetch re-upserts with the real body — index must follow
        let mut m = s.list_messages(&"t1".to_string()).unwrap()[0].clone();
        m.body_text = Some("zanzibar itinerary".to_string());
        s.upsert_message(&m).unwrap();
        assert_eq!(search(&s, "zanzibar").len(), 1);
        assert!(search(&s, "placeholder").is_empty());

        s.delete_thread(&"t1".to_string()).unwrap();
        assert!(search(&s, "zanzibar").is_empty());
    }

    #[test]
    fn search_v5_migration_rebuild_indexes_preexisting_rows() {
        // The one upgrade path every existing install takes: data written at
        // v4 (no FTS, no triggers), then opening at v5 must make it
        // searchable via the 'rebuild' backfill alone.
        let dir = std::env::temp_dir()
            .join(format!("heypigeon-test-migr-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v4.db");
        let _ = std::fs::remove_file(&path);
        {
            let conn = Connection::open(&path).unwrap();
            let s = SqliteStore::init_to(conn, 4).unwrap();
            s.upsert_account(&sample_account("a1")).unwrap();
            seed_thread(&s, "t1", "Zanzibar itinerary", "a@x.com", "flights and hotels", 1000, false);
        }
        let s = SqliteStore::open(&path).unwrap(); // runs v5 incl. rebuild
        assert_eq!(search(&s, "zanzibar").len(), 1, "subject indexed by rebuild");
        assert_eq!(search(&s, "flights").len(), 1, "body indexed by rebuild");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn search_never_errors_on_empty_or_garbage_queries() {
        let s = store();
        seed_thread(&s, "t1", "Hello", "a@x.com", "world", 1000, false);
        assert!(search(&s, "").is_empty());
        assert_eq!(search(&s, "wor").len(), 1);
        assert_eq!(search(&s, "he\"llo OR (").len(), 0); // quoted, no fts syntax error
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
