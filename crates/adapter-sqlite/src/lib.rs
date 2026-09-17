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
    // v6 — local-only "remind me" schedule (epoch ms). Never synced to
    // Gmail; sync re-upserts must not clobber it (see upsert_thread).
    "ALTER TABLE threads ADD COLUMN scheduled_at INTEGER;",
    // v7 — folder/label support. `threads.labels` = JSON array of Gmail
    // label ids (union over the thread's messages); pre-existing rows start
    // at '[]' and heal on the next backfill re-upsert. `labels` = the
    // account's user-created labels (sidebar), refreshed wholesale each sync.
    "
    ALTER TABLE threads ADD COLUMN labels TEXT NOT NULL DEFAULT '[]';
    CREATE TABLE labels (
        account_id TEXT NOT NULL REFERENCES accounts(id),
        id         TEXT NOT NULL,
        name       TEXT NOT NULL,
        PRIMARY KEY (account_id, id)
    );
    ",
    // v8 — one-time heal for the v7 upgrade: pre-existing threads sit at
    // labels='[]' and the labels table is empty until a backfill re-upserts
    // them, but delta_sync only backfills when the checkpoint is missing or
    // expired — a valid checkpoint would leave the label folders empty for
    // weeks. Clearing the checkpoint forces the sanctioned recovery path
    // (full backfill, idempotent upserts) on next startup.
    "UPDATE accounts SET history_id = NULL;",
    // v9 — attachment indicator (list-row paperclip icon). Pre-existing
    // threads default to 0/false and heal on the next backfill re-upsert,
    // same pattern as v2's last_from_addr.
    "ALTER TABLE threads ADD COLUMN has_attachment INTEGER NOT NULL DEFAULT 0;",
];

/// SQL predicate: the JSON label array in `col` contains `label`. Only
/// compile-time system-label constants may be interpolated — user label ids
/// must bind as parameters.
fn has_label_sql(col: &str, label: &str) -> String {
    format!("EXISTS (SELECT 1 FROM json_each({col}) WHERE json_each.value = '{label}')")
}

/// Junk exclusion for the non-Trash/Spam views: a thread is junk only when
/// it carries TRASH/SPAM *and* is out of the inbox. A partially-trashed
/// thread (one message trashed from another client) keeps INBOX and must not
/// vanish from All/Starred/Sent/label views while Inbox still shows it.
/// Keep in lockstep with fakes::matches_filter.
fn not_junk_sql(col: &str) -> String {
    format!(
        "NOT (({} OR {}) AND NOT {})",
        has_label_sql(col, "TRASH"),
        has_label_sql(col, "SPAM"),
        has_label_sql(col, "INBOX")
    )
}

/// WHERE-clause fragment for one `ThreadFilter` against the `threads`
/// table, plus the bound label id (when the filter needs one). `label_bind`
/// is the SQL parameter placeholder to interpolate for `ThreadFilter::Label`
/// (callers differ on which positional slot is free). Keep in lockstep with
/// fakes::matches_filter.
fn thread_filter_sql<'a>(filter: &'a ThreadFilter, label_bind: &str) -> (String, Option<&'a str>) {
    let has = |label: &str| has_label_sql("threads.labels", label);
    let not_junk = not_junk_sql("threads.labels");
    match filter {
        // Flag-based, not label-based: the optimistic local apply flips
        // the flags instantly, before any provider round-trip.
        ThreadFilter::Inbox => ("is_inbox = 1 AND is_archived = 0".to_string(), None),
        // Archive semantics: see sync::derive_is_archived — no INBOX/
        // TRASH/SPAM/DRAFT and at least one received (non-SENT) message.
        ThreadFilter::Archive => ("is_archived = 1".to_string(), None),
        ThreadFilter::All => (not_junk.clone(), None),
        ThreadFilter::Starred => (format!("{} AND {not_junk}", has("STARRED")), None),
        ThreadFilter::Sent => (format!("{} AND {not_junk}", has("SENT")), None),
        // A trashed draft belongs to Trash only (Gmail hides it from Drafts).
        ThreadFilter::Drafts => (format!("{} AND NOT {}", has("DRAFT"), has("TRASH")), None),
        ThreadFilter::Spam => (has("SPAM"), None),
        ThreadFilter::Trash => (has("TRASH"), None),
        ThreadFilter::Label(id) => (
            format!(
                "EXISTS (SELECT 1 FROM json_each(threads.labels) WHERE json_each.value = {label_bind})
                 AND {not_junk}"
            ),
            Some(id.as_str()),
        ),
    }
}

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

    /// Add/remove one label in the thread's labels JSON union. is_inbox /
    /// is_archived stay untouched — label flips never move mail between the
    /// flag-driven folders (Archive/Trash own those).
    fn flip_label(&self, thread_id: &ThreadId, label_id: &str, add: bool) -> Result<(), StoreError> {
        let Some(mut t) = self.get_thread(thread_id)? else {
            return Err(StoreError(format!("unknown thread {thread_id}")));
        };
        t.labels.retain(|l| l != label_id);
        if add {
            t.labels.push(label_id.to_string());
        }
        let labels = serde_json::to_string(&t.labels).map_err(err)?;
        self.with(|c| {
            c.execute("UPDATE threads SET labels = ?2 WHERE id = ?1", params![thread_id, labels])
        })?;
        Ok(())
    }

    /// Set or clear a thread's local "remind me" schedule (epoch ms).
    /// Local-only metadata — never synced to Gmail.
    pub fn set_schedule(
        &self,
        thread_id: &ThreadId,
        scheduled_at: Option<i64>,
    ) -> Result<(), StoreError> {
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET scheduled_at = ?2 WHERE id = ?1",
                params![thread_id, scheduled_at],
            )
        })?;
        if n == 0 {
            return Err(StoreError(format!("unknown thread {thread_id}")));
        }
        Ok(())
    }

    /// Every scheduled thread, regardless of inbox/archive state — the
    /// calendar view must keep showing reminders after the thread is
    /// archived out of the inbox window (and past the inbox page limit).
    pub fn list_scheduled(&self) -> Result<Vec<Thread>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare(&format!(
                "SELECT {THREAD_COLS} FROM threads
                 WHERE scheduled_at IS NOT NULL
                 ORDER BY scheduled_at ASC"
            ))?;
            let rows = stmt.query_map([], row_to_thread)?;
            rows.collect()
        })
    }

    /// Remove an account and everything belonging to it (used when the dev
    /// fake account is replaced by a real one).
    pub fn delete_account(&self, account_id: &str) -> Result<(), StoreError> {
        self.with(|c| {
            // One transaction: every child table (incl. labels, which
            // REFERENCES accounts under foreign_keys=ON) must go before the
            // account row, and a failure must not leave a half-wiped cache.
            let tx = c.unchecked_transaction()?;
            tx.execute("DELETE FROM outbox WHERE account_id = ?1", params![account_id])?;
            tx.execute("DELETE FROM messages WHERE account_id = ?1", params![account_id])?;
            tx.execute("DELETE FROM threads WHERE account_id = ?1", params![account_id])?;
            tx.execute("DELETE FROM labels WHERE account_id = ?1", params![account_id])?;
            tx.execute("DELETE FROM accounts WHERE id = ?1", params![account_id])?;
            tx.commit()
        })
    }

    /// Rename a stored label (optimistic local half of `users.labels.patch`;
    /// the next `set_labels` refresh confirms). Unknown ids are a no-op.
    pub fn rename_label(
        &self,
        account_id: &str,
        label_id: &str,
        new_name: &str,
    ) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "UPDATE labels SET name = ?3 WHERE account_id = ?1 AND id = ?2",
                params![account_id, label_id, new_name],
            )
            .map(|_| ())
        })
    }

    /// Remove a label locally: drop the labels-table row AND strip the id
    /// from every thread's `labels` JSON array for that account — otherwise
    /// the deleted label's threads keep matching `ThreadFilter::Label`.
    pub fn delete_label(&self, account_id: &str, label_id: &str) -> Result<(), StoreError> {
        self.with(|c| {
            let tx = c.unchecked_transaction()?;
            tx.execute(
                "DELETE FROM labels WHERE account_id = ?1 AND id = ?2",
                params![account_id, label_id],
            )?;
            // json_group_array over zero rows yields '[]', matching the
            // column default.
            tx.execute(
                "UPDATE threads SET labels =
                    (SELECT json_group_array(value) FROM json_each(threads.labels)
                     WHERE value <> ?2)
                 WHERE account_id = ?1
                   AND EXISTS (SELECT 1 FROM json_each(threads.labels) WHERE value = ?2)",
                params![account_id, label_id],
            )?;
            tx.commit()
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
        scheduled_at: r.get(11)?,
        labels: serde_json::from_str(&r.get::<_, String>(12)?).unwrap_or_default(),
        has_attachment: r.get(13)?,
    })
}

const THREAD_COLS: &str =
    "id, account_id, subject, snippet, last_msg_at, is_read, is_inbox, is_archived, msg_count, from_summary, last_from_addr, scheduled_at, labels, has_attachment";

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
        let labels = serde_json::to_string(&t.labels).map_err(err)?;
        self.with(|c| {
            // scheduled_at is deliberately absent from the column list AND
            // the UPDATE set: it is local-only metadata (never synced to
            // Gmail), so a sync re-upsert of provider data must not clobber
            // an existing schedule. Writes go through `set_schedule` only.
            // labels, by contrast, ARE provider data — re-upserts must write
            // them so the folder queries stay current.
            c.execute(
                "INSERT INTO threads (id, account_id, subject, snippet, last_msg_at, is_read,
                                      is_inbox, is_archived, msg_count, from_summary, last_from_addr,
                                      labels, has_attachment)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                     ON CONFLICT(id) DO UPDATE SET
                       subject = excluded.subject, snippet = excluded.snippet,
                       last_msg_at = excluded.last_msg_at, is_read = excluded.is_read,
                       is_inbox = excluded.is_inbox, is_archived = excluded.is_archived,
                       msg_count = excluded.msg_count, from_summary = excluded.from_summary,
                       last_from_addr = excluded.last_from_addr, labels = excluded.labels,
                       has_attachment = excluded.has_attachment",
                params![
                    t.id, t.account_id, t.subject, t.snippet, t.last_msg_at,
                    t.is_read, t.is_inbox, t.is_archived, t.msg_count, t.from_summary,
                    t.last_from_addr, labels, t.has_attachment
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
        filter: &ThreadFilter,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<Thread>, StoreError> {
        // json_each over the (small) thread label array — only fixed system
        // label ids are interpolated; user label ids bind as ?4.
        let (cond, label_param) = thread_filter_sql(filter, "?4");
        self.with(|c| {
            // Keyset pagination — never OFFSET (DESIGN.md).
            let mut stmt = c.prepare(&format!(
                "SELECT {THREAD_COLS} FROM threads
                 WHERE ({cond})
                   AND (?1 IS NULL OR account_id = ?1)
                   AND (?2 IS NULL OR last_msg_at < ?2)
                 ORDER BY last_msg_at DESC
                 LIMIT ?3"
            ))?;
            let rows = match label_param {
                Some(id) => stmt.query_map(params![account_id, before, limit, id], row_to_thread)?,
                None => stmt.query_map(params![account_id, before, limit], row_to_thread)?,
            };
            rows.collect()
        })
    }

    /// Unread thread count for one folder/label filter (sidebar badges) —
    /// a plain COUNT(*), no row hydration.
    fn count_unread(
        &self,
        account_id: Option<&AccountId>,
        filter: &ThreadFilter,
    ) -> Result<i64, StoreError> {
        let (cond, label_param) = thread_filter_sql(filter, "?2");
        self.with(|c| {
            let sql = format!(
                "SELECT COUNT(*) FROM threads
                 WHERE ({cond}) AND is_read = 0
                   AND (?1 IS NULL OR account_id = ?1)"
            );
            let mut stmt = c.prepare(&sql)?;
            match label_param {
                Some(id) => stmt.query_row(params![account_id, id], |r| r.get(0)),
                None => stmt.query_row(params![account_id], |r| r.get(0)),
            }
        })
    }

    fn set_labels(&self, account_id: &AccountId, labels: &[Label]) -> Result<(), StoreError> {
        self.with(|c| {
            // Wholesale replace: labels deleted upstream must disappear.
            c.execute("DELETE FROM labels WHERE account_id = ?1", params![account_id])?;
            let mut stmt =
                c.prepare("INSERT INTO labels (account_id, id, name) VALUES (?1, ?2, ?3)")?;
            for l in labels {
                stmt.execute(params![account_id, l.id, l.name])?;
            }
            Ok(())
        })
    }

    fn list_labels(&self) -> Result<Vec<Label>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT account_id, id, name FROM labels
                 ORDER BY name COLLATE NOCASE, account_id",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok(Label { account_id: r.get(0)?, id: r.get(1)?, name: r.get(2)? })
            })?;
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
        // Backfill deliberately ingests the whole spam/trash corpus (the
        // Trash/Spam folders list locally) — but search must not surface it.
        let not_junk = not_junk_sql("t.labels");
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
                       AND {not_junk}
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
                            // THREAD_COLS width, not a magic number — `snip` is
                            // selected right after all thread_cols().
                            snippet: r.get(THREAD_COLS.split(", ").count())?,
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
                       AND {not_junk}
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
        // Archive/Trash also flip the thread-level labels so the folder
        // queries agree with the optimistic state before the next delta sync
        // (which recomputes the union from message labels anyway).
        let (thread_id, flags) = match mutation {
            Mutation::MarkRead { thread_id, read } => {
                let n = self.with(|c| {
                    c.execute(
                        "UPDATE threads SET is_read = ?2 WHERE id = ?1",
                        params![thread_id, read],
                    )
                })?;
                if n == 0 {
                    return Err(StoreError(format!("unknown thread {thread_id}")));
                }
                return Ok(());
            }
            // Nothing changes locally for outgoing mail (no local Sent write
            // — the sent thread lands via the next delta sync).
            Mutation::Send { .. } => return Ok(()),
            // Star is sugar over a STARRED label flip; both leave flags alone.
            Mutation::Star { thread_id, starred } => {
                return self.flip_label(thread_id, "STARRED", *starred);
            }
            Mutation::ModifyLabel { thread_id, label_id, add } => {
                return self.flip_label(thread_id, label_id, *add);
            }
            Mutation::Archive { thread_id } => (thread_id, (true, false)),
            Mutation::Unarchive { thread_id } => (thread_id, (false, true)),
            Mutation::Trash { thread_id } => (thread_id, (false, false)),
        };
        let Some(mut t) = self.get_thread(thread_id)? else {
            return Err(StoreError(format!("unknown thread {thread_id}")));
        };
        let (is_archived, is_inbox) = flags;
        if matches!(mutation, Mutation::Unarchive { .. }) {
            if !t.labels.iter().any(|l| l == "INBOX") {
                t.labels.push("INBOX".to_string());
            }
        } else {
            t.labels.retain(|l| l != "INBOX");
            if matches!(mutation, Mutation::Trash { .. }) && !t.labels.iter().any(|l| l == "TRASH") {
                t.labels.push("TRASH".to_string());
            }
        }
        let labels = serde_json::to_string(&t.labels).map_err(err)?;
        self.with(|c| {
            c.execute(
                "UPDATE threads SET is_archived = ?2, is_inbox = ?3, labels = ?4 WHERE id = ?1",
                params![thread_id, is_archived, is_inbox, labels],
            )
        })?;
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
        let threads = store.list_threads(None, &ThreadFilter::Inbox, None, 100).unwrap();
        assert_eq!(threads.len(), 25);
        assert!(threads.windows(2).all(|w| w[0].last_msg_at >= w[1].last_msg_at));

        // keyset pagination: second page strictly older, no overlap
        let page1 = store.list_threads(None, &ThreadFilter::Inbox, None, 10).unwrap();
        let page2 = store
            .list_threads(None, &ThreadFilter::Inbox, Some(page1.last().unwrap().last_msg_at), 10)
            .unwrap();
        assert_eq!(page2.len(), 10);
        assert!(page2[0].last_msg_at < page1.last().unwrap().last_msg_at);
    }

    #[tokio::test]
    async fn messages_round_trip() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();

        let t = &store.list_threads(None, &ThreadFilter::Inbox, None, 1).unwrap()[0];
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
        let id = store.list_threads(None, &ThreadFilter::Inbox, None, 1).unwrap()[0].id.clone();

        outbox::enqueue(&store, &"a1".to_string(), Mutation::Archive { thread_id: id.clone() }).unwrap();

        // local view updated instantly; thread gone from inbox list
        assert!(store.get_thread(&id).unwrap().unwrap().is_archived);
        assert!(!store.list_threads(None, &ThreadFilter::Inbox, None, 10).unwrap().iter().any(|t| t.id == id));

        let (applied, failed) = outbox::drain(&provider, &store, 10).await.unwrap();
        assert_eq!((applied, failed), (1, 0));
        assert!(store.outbox_list(10).unwrap().is_empty());
    }

    #[tokio::test]
    async fn metadata_reupsert_preserves_fetched_bodies() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 1, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();
        let t = store.list_threads(None, &ThreadFilter::Inbox, None, 1).unwrap()[0].clone();
        let mut m = store.list_messages(&t.id).unwrap()[0].clone();
        assert!(m.body_text.is_some(), "fixture has a body");

        // Metadata-tier refetch of the same message carries no bodies.
        m.body_html = None;
        m.body_text = None;
        store.upsert_message(&m).unwrap();

        let after = store.list_messages(&t.id).unwrap()[0].clone();
        assert!(after.body_text.is_some(), "body survives metadata re-upsert");
    }

    #[tokio::test]
    async fn scheduled_at_survives_sync_reupsert() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();
        let id = store.list_threads(None, &ThreadFilter::Inbox, None, 1).unwrap()[0].id.clone();

        store.set_schedule(&id, Some(1_756_700_000_000)).unwrap();
        assert_eq!(
            store.get_thread(&id).unwrap().unwrap().scheduled_at,
            Some(1_756_700_000_000)
        );

        // Delta/backfill re-upserts the same thread from provider data
        // (which never carries a schedule) — must not clobber it.
        sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();
        assert_eq!(
            store.get_thread(&id).unwrap().unwrap().scheduled_at,
            Some(1_756_700_000_000),
            "schedule survives provider re-upsert"
        );

        // Listing exposes it too (drives the calendar view).
        let listed = store.list_threads(None, &ThreadFilter::Inbox, None, 10).unwrap();
        assert_eq!(
            listed.iter().find(|t| t.id == id).unwrap().scheduled_at,
            Some(1_756_700_000_000)
        );

        // Clearing works and unknown threads error.
        store.set_schedule(&id, None).unwrap();
        assert_eq!(store.get_thread(&id).unwrap().unwrap().scheduled_at, None);
        assert!(store.set_schedule(&"nope".to_string(), Some(1)).is_err());
    }

    #[tokio::test]
    async fn list_scheduled_includes_archived_threads() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();
        let id = store.list_threads(None, &ThreadFilter::Inbox, None, 1).unwrap()[0].id.clone();
        store.set_schedule(&id, Some(42)).unwrap();

        // "Remind later" flow: schedule, then archive to clear the inbox.
        outbox::enqueue(&store, &"a1".to_string(), Mutation::Archive { thread_id: id.clone() })
            .unwrap();
        assert!(
            !store.list_threads(None, &ThreadFilter::Inbox, None, 10).unwrap().iter().any(|t| t.id == id),
            "archived thread leaves the inbox list"
        );

        // ...but the calendar feed still shows it.
        let scheduled = store.list_scheduled().unwrap();
        assert_eq!(scheduled.iter().filter(|t| t.id == id).count(), 1);
        assert_eq!(scheduled.iter().find(|t| t.id == id).unwrap().scheduled_at, Some(42));

        // Clearing the schedule removes it from the feed.
        store.set_schedule(&id, None).unwrap();
        assert!(!store.list_scheduled().unwrap().iter().any(|t| t.id == id));
    }

    // ------------------------------------------------------------- folders

    fn seed_labelled(
        s: &SqliteStore,
        id: &str,
        labels: &[&str],
        is_inbox: bool,
        is_archived: bool,
        last_msg_at: i64,
    ) {
        s.upsert_thread(&Thread {
            id: id.to_string(),
            account_id: "a1".to_string(),
            subject: format!("Subject {id}"),
            snippet: String::new(),
            last_msg_at,
            is_read: true,
            is_inbox,
            is_archived,
            msg_count: 1,
            from_summary: "Someone".to_string(),
            last_from_addr: "someone@example.com".to_string(),
            scheduled_at: None,
            labels: labels.iter().map(|s| s.to_string()).collect(),
            has_attachment: false,
        })
        .unwrap();
    }

    fn ids(s: &SqliteStore, f: &ThreadFilter) -> Vec<String> {
        let mut v: Vec<String> =
            s.list_threads(None, f, None, 100).unwrap().into_iter().map(|t| t.id).collect();
        v.sort();
        v
    }

    #[test]
    fn folder_filters_query_thread_labels() {
        let s = store();
        seed_labelled(&s, "in", &["INBOX"], true, false, 8000);
        seed_labelled(&s, "star", &["INBOX", "STARRED"], true, false, 7000);
        seed_labelled(&s, "sent", &["SENT"], false, false, 6000);
        seed_labelled(&s, "draft", &["DRAFT"], false, false, 5000);
        seed_labelled(&s, "spam", &["SPAM"], false, false, 4000);
        seed_labelled(&s, "trash", &["TRASH"], false, false, 3000);
        seed_labelled(&s, "arch", &["Label_9"], false, true, 2000);
        // trashed starred/labelled mail must not leak into Starred/label views
        seed_labelled(&s, "trash-star", &["STARRED", "TRASH", "Label_9"], false, false, 1000);
        // partially-trashed thread (one message trashed elsewhere) keeps
        // INBOX — still lives in Inbox AND All, plus Trash
        seed_labelled(&s, "part-trash", &["INBOX", "TRASH"], true, false, 900);
        // a trashed draft belongs to Trash only, not Drafts
        seed_labelled(&s, "trash-draft", &["DRAFT", "TRASH"], false, false, 800);

        assert_eq!(ids(&s, &ThreadFilter::Inbox), ["in", "part-trash", "star"]);
        assert_eq!(ids(&s, &ThreadFilter::Starred), ["star"]);
        assert_eq!(ids(&s, &ThreadFilter::Sent), ["sent"]);
        assert_eq!(ids(&s, &ThreadFilter::Drafts), ["draft"], "trashed draft hidden from Drafts");
        assert_eq!(ids(&s, &ThreadFilter::Spam), ["spam"]);
        assert_eq!(
            ids(&s, &ThreadFilter::Trash),
            ["part-trash", "trash", "trash-draft", "trash-star"]
        );
        assert_eq!(ids(&s, &ThreadFilter::Archive), ["arch"]);
        assert_eq!(
            ids(&s, &ThreadFilter::Label("Label_9".to_string())),
            ["arch"],
            "label view hides trashed mail"
        );
        assert_eq!(
            ids(&s, &ThreadFilter::All),
            ["arch", "draft", "in", "part-trash", "sent", "star"],
            "All hides trash + spam but keeps the partially-trashed inbox thread"
        );

        // keyset pagination works under a filter too
        let page1 = s.list_threads(None, &ThreadFilter::Trash, None, 1).unwrap();
        assert_eq!(page1[0].id, "trash");
        let page2 = s
            .list_threads(None, &ThreadFilter::Trash, Some(page1[0].last_msg_at), 1)
            .unwrap();
        assert_eq!(page2[0].id, "trash-star");
    }

    #[test]
    fn count_unread_matches_filter_account_and_read_state() {
        let s = store();
        s.upsert_account(&sample_account("a2")).unwrap();
        let mk = |id: &str, account: &str, labels: &[&str], is_inbox: bool, is_read: bool| Thread {
            id: id.to_string(),
            account_id: account.to_string(),
            subject: String::new(),
            snippet: String::new(),
            last_msg_at: 1,
            is_read,
            is_inbox,
            is_archived: false,
            msg_count: 1,
            from_summary: "Someone".to_string(),
            last_from_addr: "someone@example.com".to_string(),
            scheduled_at: None,
            labels: labels.iter().map(|s| s.to_string()).collect(),
            has_attachment: false,
        };
        s.upsert_thread(&mk("a-unread", "a1", &["INBOX"], true, false)).unwrap();
        s.upsert_thread(&mk("a-read", "a1", &["INBOX"], true, true)).unwrap();
        s.upsert_thread(&mk("b-unread", "a2", &["INBOX"], true, false)).unwrap();
        // not in the inbox — must not count toward Inbox, only its own label
        s.upsert_thread(&mk("a-label-unread", "a1", &["Label_1"], false, false)).unwrap();

        assert_eq!(s.count_unread(None, &ThreadFilter::Inbox).unwrap(), 2, "both accounts");
        assert_eq!(
            s.count_unread(Some(&"a1".to_string()), &ThreadFilter::Inbox).unwrap(),
            1,
            "account-scoped"
        );
        assert_eq!(
            s.count_unread(Some(&"a1".to_string()), &ThreadFilter::Label("Label_1".to_string()))
                .unwrap(),
            1
        );
        assert_eq!(
            s.count_unread(Some(&"a1".to_string()), &ThreadFilter::Label("Label_2".to_string()))
                .unwrap(),
            0,
            "non-matching label"
        );
    }

    #[test]
    fn trash_apply_local_moves_thread_into_trash_folder() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 1000);
        s.apply_local(&Mutation::Trash { thread_id: "t1".to_string() }).unwrap();
        assert_eq!(ids(&s, &ThreadFilter::Inbox), Vec::<String>::new());
        assert_eq!(ids(&s, &ThreadFilter::Trash), ["t1"]);
        // archive: INBOX label drops so the thread leaves the label-derived views
        seed_labelled(&s, "t2", &["INBOX", "STARRED"], true, false, 1000);
        s.apply_local(&Mutation::Archive { thread_id: "t2".to_string() }).unwrap();
        let t2 = s.get_thread(&"t2".to_string()).unwrap().unwrap();
        assert!(t2.is_archived && !t2.is_inbox);
        assert_eq!(t2.labels, vec!["STARRED".to_string()]);
    }

    #[test]
    fn unarchive_apply_local_restores_thread_to_inbox() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX", "STARRED"], true, false, 1000);
        s.apply_local(&Mutation::Archive { thread_id: "t1".to_string() }).unwrap();
        assert_eq!(ids(&s, &ThreadFilter::Inbox), Vec::<String>::new());

        s.apply_local(&Mutation::Unarchive { thread_id: "t1".to_string() }).unwrap();
        let t1 = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert!(t1.is_inbox && !t1.is_archived);
        assert_eq!(t1.labels, vec!["STARRED".to_string(), "INBOX".to_string()]);
        assert_eq!(ids(&s, &ThreadFilter::Inbox), ["t1"]);

        // idempotent: unarchiving an already-inbox thread doesn't duplicate INBOX
        s.apply_local(&Mutation::Unarchive { thread_id: "t1".to_string() }).unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string()).unwrap().unwrap().labels,
            vec!["STARRED".to_string(), "INBOX".to_string()]
        );
    }

    #[test]
    fn star_and_modify_label_apply_local_flip_labels_only() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 1000);
        let star = |on: bool| Mutation::Star { thread_id: "t1".to_string(), starred: on };
        s.apply_local(&star(true)).unwrap();
        let t = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t.labels, ["INBOX", "STARRED"]);
        assert!(t.is_inbox && !t.is_archived, "star must not move the thread");
        assert_eq!(ids(&s, &ThreadFilter::Starred), ["t1"]);
        // idempotent: starring again doesn't duplicate the label
        s.apply_local(&star(true)).unwrap();
        assert_eq!(s.get_thread(&"t1".to_string()).unwrap().unwrap().labels, ["INBOX", "STARRED"]);
        s.apply_local(&star(false)).unwrap();
        assert_eq!(s.get_thread(&"t1".to_string()).unwrap().unwrap().labels, ["INBOX"]);
        assert_eq!(ids(&s, &ThreadFilter::Starred), Vec::<String>::new());
        // generic label flip: same machinery, same guarantees
        let flip = |add: bool| Mutation::ModifyLabel {
            thread_id: "t1".to_string(),
            label_id: "Label_7".to_string(),
            add,
        };
        s.apply_local(&flip(true)).unwrap();
        assert_eq!(ids(&s, &ThreadFilter::Label("Label_7".to_string())), ["t1"]);
        s.apply_local(&flip(false)).unwrap();
        let t = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t.labels, ["INBOX"]);
        assert!(t.is_inbox && !t.is_archived);
        // unknown thread errors like the other mutations
        let missing = Mutation::Star { thread_id: "nope".to_string(), starred: true };
        assert!(s.apply_local(&missing).is_err());
    }

    #[test]
    fn labels_roundtrip_and_replace() {
        let s = store();
        let l = |id: &str, name: &str| Label {
            account_id: "a1".to_string(),
            id: id.to_string(),
            name: name.to_string(),
        };
        s.set_labels(&"a1".to_string(), &[l("L1", "zeta"), l("L2", "Alpha")]).unwrap();
        let listed = s.list_labels().unwrap();
        assert_eq!(
            listed.iter().map(|x| x.name.as_str()).collect::<Vec<_>>(),
            ["Alpha", "zeta"],
            "name-sorted, case-insensitive"
        );
        // wholesale replace: deleted labels disappear
        s.set_labels(&"a1".to_string(), &[l("L2", "Alpha renamed")]).unwrap();
        let listed = s.list_labels().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, "L2");
        assert_eq!(listed[0].name, "Alpha renamed");
    }

    #[test]
    fn rename_and_delete_label_update_rows_and_strip_threads() {
        let s = store();
        let l = |id: &str, name: &str| Label {
            account_id: "a1".to_string(),
            id: id.to_string(),
            name: name.to_string(),
        };
        s.set_labels(&"a1".to_string(), &[l("L1", "Old"), l("L2", "Keep")]).unwrap();
        seed_labelled(&s, "t1", &["INBOX", "L1"], true, false, 2000);
        seed_labelled(&s, "t2", &["L1", "L2"], false, true, 1000);

        s.rename_label("a1", "L1", "New").unwrap();
        let names: Vec<String> =
            s.list_labels().unwrap().into_iter().map(|x| x.name).collect();
        assert_eq!(names, ["Keep", "New"]);

        s.delete_label("a1", "L1").unwrap();
        let listed = s.list_labels().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, "L2");
        // threads no longer carry the deleted id…
        assert_eq!(s.get_thread(&"t1".to_string()).unwrap().unwrap().labels, ["INBOX"]);
        assert_eq!(s.get_thread(&"t2".to_string()).unwrap().unwrap().labels, ["L2"]);
        // …so the label view is empty while other labels keep working.
        assert_eq!(ids(&s, &ThreadFilter::Label("L1".to_string())), Vec::<String>::new());
        assert_eq!(ids(&s, &ThreadFilter::Label("L2".to_string())), ["t2"]);
    }

    #[test]
    fn v7_migration_upgrades_existing_data() {
        let dir = std::env::temp_dir().join(format!("heypigeon-test-v7-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v6.db");
        let _ = std::fs::remove_file(&path);
        {
            let conn = Connection::open(&path).unwrap();
            let _ = SqliteStore::init_to(conn, 6).unwrap();
        }
        {
            // Raw v6-shape rows — upsert_thread would already write `labels`.
            let conn = Connection::open(&path).unwrap();
            conn.execute(
                "INSERT INTO accounts (id, email, display_name, color, history_id)
                 VALUES ('a1', 'a1@example.com', 'A1', 'sky', 'hist-42')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO threads (id, account_id, subject, snippet, last_msg_at, is_read,
                                      is_inbox, is_archived, msg_count, from_summary)
                 VALUES ('t1', 'a1', 'Old row', 'snip', 1000, 1, 1, 0, 1, 'Someone')",
                [],
            )
            .unwrap();
        }
        let s = SqliteStore::open(&path).unwrap(); // runs v7 + v8
        let t = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert!(t.labels.is_empty(), "pre-v7 rows default to '[]', healed by backfill");
        assert_eq!(ids(&s, &ThreadFilter::Inbox), ["t1"]);
        assert!(s.list_labels().unwrap().is_empty());
        // v8 clears the checkpoint so the next delta_sync actually runs the
        // healing backfill — a valid checkpoint would otherwise leave the
        // label folders empty until history expiry.
        assert!(
            s.list_accounts().unwrap()[0].history_id.is_none(),
            "v8 forces a one-time backfill after the labels upgrade"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn delete_account_removes_labels_and_children() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();
        assert!(!store.list_labels().unwrap().is_empty(), "backfill stored labels");

        // Must not hit "FOREIGN KEY constraint failed" from the labels table.
        store.delete_account("a1").unwrap();

        assert!(store.list_accounts().unwrap().is_empty());
        assert!(store.list_labels().unwrap().is_empty());
        assert!(store.list_threads(None, &ThreadFilter::All, None, 10).unwrap().is_empty());
        assert!(store.outbox_list(10).unwrap().is_empty());
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
            scheduled_at: None,
            labels: vec!["INBOX".to_string()],
            has_attachment: false,
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
    fn search_excludes_spam_and_trash() {
        let s = store();
        seed_thread(&s, "keep", "Invoice due", "a@x.com", "pay the invoice", 3000, false);
        seed_thread(&s, "junk-spam", "Invoice prize", "b@x.com", "win an invoice", 2000, false);
        seed_thread(&s, "junk-trash", "Invoice old", "c@x.com", "stale invoice", 1000, false);
        for (id, label) in [("junk-spam", "SPAM"), ("junk-trash", "TRASH")] {
            let mut t = s.get_thread(&id.to_string()).unwrap().unwrap();
            t.labels = vec![label.to_string()];
            t.is_inbox = false;
            s.upsert_thread(&t).unwrap();
        }

        // FTS branch
        let hits = search(&s, "invoice");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].thread.id, "keep");
        // operators-only branch
        let hits = search(&s, "from:x.com");
        assert_eq!(
            hits.iter().map(|h| h.thread.id.as_str()).collect::<Vec<_>>(),
            ["keep"]
        );

        // A partially-trashed thread still in the inbox stays searchable.
        let mut t = s.get_thread(&"junk-trash".to_string()).unwrap().unwrap();
        t.labels = vec!["INBOX".to_string(), "TRASH".to_string()];
        t.is_inbox = true;
        s.upsert_thread(&t).unwrap();
        assert_eq!(search(&s, "invoice").len(), 2);
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
            let _ = SqliteStore::init_to(conn, 4).unwrap();
        }
        {
            // Raw v4-shape rows — upsert_thread would already write the v7
            // `labels` column, which doesn't exist yet at v4.
            let conn = Connection::open(&path).unwrap();
            conn.execute(
                "INSERT INTO accounts (id, email, display_name, color)
                 VALUES ('a1', 'a1@example.com', 'A1', 'sky')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO threads (id, account_id, subject, snippet, last_msg_at, is_read,
                                      is_inbox, is_archived, msg_count, from_summary)
                 VALUES ('t1', 'a1', 'Zanzibar itinerary', 'flights and hotels', 1000, 1, 1, 0, 1, 'a@x.com')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (id, thread_id, account_id, from_addr, to_addrs, date,
                                       snippet, body_text, label_ids, is_read)
                 VALUES ('t1-m1', 't1', 'a1', 'a@x.com', '[]', 1000,
                         'flights and hotels', 'flights and hotels', '[\"INBOX\"]', 1)",
                [],
            )
            .unwrap();
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
