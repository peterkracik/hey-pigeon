//! SQLite adapter: implements `Store`.
//! WAL mode, migration-only schema (user_version pragma). One writer
//! connection and a few readers, each behind its own mutex: every write
//! and the background passes' own queries go through the writer; the reads
//! (`read`) go through whichever reader is free, so a list or a count never
//! waits for a sync page to commit — WAL lets readers and the writer work
//! at once — nor for another read (a search in flight used to hold up the
//! row the main thread asked for). The DB is a cache — worst case is drop
//! + re-sync.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Duration;

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
    // v10 — cross-device sync (DESIGN.md "Cross-device sync"). `sync_kv` is
    // the per-account last-writer-wins map (value = JSON, NULL = tombstone);
    // `sync_meta` is loop bookkeeping (remote file id, fingerprints) plus,
    // under account_id '', the install-wide device id.
    "
    CREATE TABLE sync_kv (
        account_id TEXT NOT NULL REFERENCES accounts(id),
        key        TEXT NOT NULL,
        value      TEXT,
        ts         INTEGER NOT NULL,
        device     TEXT NOT NULL,
        PRIMARY KEY (account_id, key)
    );
    CREATE TABLE sync_meta (
        account_id TEXT NOT NULL,
        key        TEXT NOT NULL,
        value      TEXT NOT NULL,
        PRIMARY KEY (account_id, key)
    );
    ",
    // v11 — Jev auto-triage (local-only labels + priority). `triage_labels`
    // is a small global list (Settings-managed, not per-account like Gmail
    // `labels`). `threads.triage_label_ids` is a JSON array of
    // `triage_labels.id`, replaced wholesale per classification — same
    // shape as the existing Gmail `labels` column, so `delete_triage_label`
    // reuses `delete_label`'s strip-from-JSON pattern. `triage_msg_count` is
    // the `msg_count` a thread was last classified at: NULL or stale (≠
    // current msg_count) means `list_threads_needing_triage` returns it —
    // covers "never classified" and "new message arrived" with one check.
    // All three are deliberately absent from `upsert_thread`'s column list:
    // local-only, like `scheduled_at`.
    "
    CREATE TABLE triage_labels (
        id   INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT COLLATE NOCASE NOT NULL UNIQUE
    );
    ALTER TABLE threads ADD COLUMN triage_label_ids TEXT NOT NULL DEFAULT '[]';
    ALTER TABLE threads ADD COLUMN priority TEXT;
    ALTER TABLE threads ADD COLUMN triage_msg_count INTEGER;
    ",
    // v12 — manual triage-label overrides (Peter's decision: sticky, not
    // fed back into future Jev requests). 0/default = Jev owns the labels;
    // 1 = the user edited them directly (footer "+" menu / badge ×), so
    // `set_thread_triage` must leave `triage_label_ids` alone on the next
    // auto-classification — only `priority`/`triage_msg_count` keep
    // updating. `reset_triage` ("Reanalyze all emails") clears the pin.
    "ALTER TABLE threads ADD COLUMN triage_labels_manual INTEGER NOT NULL DEFAULT 0;",
    // v13 — local-only "needs reply" flag (the user marked the thread as
    // waiting on their answer). Same contract as `scheduled_at`: absent from
    // `upsert_thread`'s column list so provider re-upserts never clobber it;
    // writes go through `set_needs_reply` only and reach other devices via
    // the cross-device sync map (`needs_reply:<thread_id>` keys).
    "ALTER TABLE threads ADD COLUMN needs_reply INTEGER NOT NULL DEFAULT 0;",
    // "Remind me if no reply": epoch ms the follow-up was armed, NULL when
    // the schedule is a plain reminder. Local-only like scheduled_at —
    // `upsert_thread` never touches it; writes go through `set_follow_up`
    // and the cross-device sync map (`follow_up:<thread_id>` keys).
    "ALTER TABLE threads ADD COLUMN follow_up_since INTEGER;",
    // v15 — settings sync (DESIGN.md "Cross-device sync", issue #17).
    // `prefs` holds the app-wide JSON preferences that travel between
    // devices (`pref:<name>` keys); the two that used to live in the secret
    // store (`ai.openai.model`, `triage.enabled`) migrate in at startup.
    // Triage label ids become random 128-bit hex instead of AUTOINCREMENT:
    // labels now sync by id, and two installs both minting "1" would merge
    // one device's "Bills" into the other's "Work". Existing rows get fresh
    // ids and every thread's `triage_label_ids` array is rewritten to
    // match. The UNIQUE(name) constraint goes too — a label created with
    // the same name on two devices before they ever synced must survive
    // the merge as two rows (the user deletes one); `create_triage_label`
    // keeps rejecting duplicates for local creation.
    "
    CREATE TABLE prefs (
        name  TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE triage_labels_v15 (
        id   TEXT PRIMARY KEY,
        name TEXT COLLATE NOCASE NOT NULL
    );
    CREATE TEMP TABLE triage_id_map AS
      SELECT CAST(id AS TEXT) AS old_id, lower(hex(randomblob(16))) AS new_id, name
      FROM triage_labels;
    INSERT INTO triage_labels_v15 (id, name) SELECT new_id, name FROM triage_id_map;
    UPDATE threads SET triage_label_ids =
        (SELECT json_group_array(COALESCE(
            (SELECT m.new_id FROM triage_id_map m WHERE m.old_id = je.value), je.value))
         FROM json_each(threads.triage_label_ids) je)
     WHERE triage_label_ids <> '[]';
    DROP TABLE triage_id_map;
    DROP TABLE triage_labels;
    ALTER TABLE triage_labels_v15 RENAME TO triage_labels;
    ",
    // v16 — one-time heal for the list-row sender rule (a replied thread
    // names the other party, not the user). `from_summary` /
    // `last_from_addr` are derived at upsert time, and delta_sync only
    // rebuilds threads that change, so rows the user already replied to
    // would keep naming the user until they happened to be touched. Same
    // recovery as v8: clearing the checkpoint forces a full backfill
    // (idempotent upserts) on next startup, which rewrites every row.
    "UPDATE accounts SET history_id = NULL;",
    // v17 — the v16 backfill only reaches the sync window (30 days), so
    // older replied threads kept naming the user. This step is a marker:
    // `init_to` follows it with `heal_list_senders`, a Rust pass that
    // re-derives every cached thread's `from_summary` / `last_from_addr`
    // from its stored messages, no network needed.
    "SELECT 1;",
    // v18 — AI suggestion for a new unread email ("Need reply", or
    // "Remind me" at a date the email names). `suggestion` is the proposal
    // as JSON (`{"kind":"needs_reply"}`, `{"kind":"remind","at":<ms>}`),
    // NULL when there is none (never asked, nothing to suggest, accepted or
    // dismissed). `suggestion_msg_count` is the `msg_count` the last
    // analysis covered — the triage versioning rule, so a new message makes
    // the thread due again and a dismissed one is never re-proposed. Both
    // local-only and absent from `upsert_thread`, like `priority`.
    "
    ALTER TABLE threads ADD COLUMN suggestion TEXT;
    ALTER TABLE threads ADD COLUMN suggestion_msg_count INTEGER;
    ",
    // v19 — bundles (docs/bundles.md). App-local like triage labels; ids are
    // random hex minted by the core. A thread is in at most one bundle, so
    // membership is two columns on `threads` (`bundle_source`: user | link)
    // rather than a join table. `thread_anchors` holds the identifiers
    // `bundles::extract_anchors` found (`order:112-334`), indexed by anchor
    // for the link lookup; `anchors_msg_count` is the triage versioning
    // rule, so a new message makes the thread due for a rescan. Exclusions
    // are the user's "not this one": nothing automatic re-adds the thread.
    // All local-only and absent from `upsert_thread`, like `priority`.
    "
    CREATE TABLE bundles (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        kind        TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        status      TEXT NOT NULL,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
    );
    ALTER TABLE threads ADD COLUMN bundle_id TEXT;
    ALTER TABLE threads ADD COLUMN bundle_source TEXT;
    ALTER TABLE threads ADD COLUMN anchors_msg_count INTEGER;
    CREATE INDEX threads_by_bundle ON threads(bundle_id);
    CREATE TABLE thread_anchors (
        thread_id TEXT NOT NULL,
        anchor    TEXT NOT NULL,
        PRIMARY KEY (thread_id, anchor)
    );
    CREATE INDEX thread_anchors_by_anchor ON thread_anchors(anchor);
    CREATE TABLE bundle_exclusions (
        bundle_id TEXT NOT NULL,
        thread_id TEXT NOT NULL,
        PRIMARY KEY (bundle_id, thread_id)
    );
    ",
    // v20 — automatic bundles. `bundles.origin` (user | ai): the model's
    // bundles stay on this device until the user touches one.
    // `bundle_ai_msg_count` is the `msg_count` the model last grouped the
    // thread at — the triage versioning rule, so each message is asked
    // about once. Local-only, absent from `upsert_thread`.
    "
    ALTER TABLE bundles ADD COLUMN origin TEXT NOT NULL DEFAULT 'user';
    ALTER TABLE threads ADD COLUMN bundle_ai_msg_count INTEGER;
    ",
    // v21 — the unread rows on their own: `unread_counts` reads them in one
    // pass after every reload (the badge, the sidebar, the widgets), and the
    // rest of the table — read mail, the bulk of it — stays out of the way.
    "CREATE INDEX idx_threads_unread ON threads (account_id, last_msg_at DESC) WHERE is_read = 0;",
    // v22 — what the list tier now keeps of a message's headers, and
    // whether its full form was ever fetched.
    // `cc_addrs` (JSON array, like `to_addrs`) is for reply-all;
    // `message_id_header` / `references_header` build a reply's
    // In-Reply-To / References; `list_unsubscribe` (+ the RFC 8058
    // one-click flag) is the unsubscribe action. `body_fetched` replaces
    // "has a body" as the test for "needs a full fetch": a message with no
    // text at all never gets a body, and its thread was fetched on every
    // open. It starts at 0 for every existing row on purpose — each old
    // thread is fetched in full once more on its next open, which is also
    // what fills the new header columns for mail synced before them.
    "
    ALTER TABLE messages ADD COLUMN cc_addrs TEXT NOT NULL DEFAULT '[]';
    ALTER TABLE messages ADD COLUMN message_id_header TEXT;
    ALTER TABLE messages ADD COLUMN references_header TEXT;
    ALTER TABLE messages ADD COLUMN list_unsubscribe TEXT;
    ALTER TABLE messages ADD COLUMN list_unsubscribe_one_click INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE messages ADD COLUMN body_fetched INTEGER NOT NULL DEFAULT 0;
    ",
    // v23 — re-index a message for search only when its indexed text
    // changed. The v5 update trigger fired on every re-upsert: new mail in
    // a thread re-upserts all its messages (label and read state), and
    // each one was taken out of the index and tokenized again, body and
    // all. The condition compares exactly the values the index holds
    // (subject lives on the thread and does not change), so the 'delete'
    // row still matches what was indexed.
    "
    DROP TRIGGER messages_fts_au;
    CREATE TRIGGER messages_fts_au AFTER UPDATE ON messages
    WHEN old.from_addr IS NOT new.from_addr
      OR old.to_addrs IS NOT new.to_addrs
      OR COALESCE(old.body_text, old.snippet, '') IS NOT COALESCE(new.body_text, new.snippet, '')
    BEGIN
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
    ",
    // v24 — the list views other than the inbox. They had no index: All
    // mail, Archive, Sent, Starred and every label read the whole table,
    // ran json_each on each row and sorted, for one page.
    // `idx_threads_time` gives the newest-first order to the views most
    // mail belongs to (All mail), and the 30-day window to the background
    // passes. `thread_labels` is `threads.labels` unfolded, one row per
    // thread and label, keyed so that "this label, newest first" is one
    // range of the primary key — Starred, Sent, Drafts, Spam, Trash and
    // the user's labels read it. Triggers keep it in step with the JSON
    // column, which stays the truth (the folder rules and the unread
    // counts read it); the last statement fills it for existing mail.
    "
    CREATE INDEX idx_threads_time ON threads (last_msg_at DESC);
    CREATE TABLE thread_labels (
        label_id    TEXT NOT NULL,
        last_msg_at INTEGER NOT NULL,
        thread_id   TEXT NOT NULL,
        PRIMARY KEY (label_id, last_msg_at, thread_id)
    ) WITHOUT ROWID;
    CREATE INDEX thread_labels_by_thread ON thread_labels (thread_id);
    CREATE TRIGGER threads_labels_ai AFTER INSERT ON threads BEGIN
        INSERT OR IGNORE INTO thread_labels (label_id, last_msg_at, thread_id)
        SELECT je.value, new.last_msg_at, new.id
          FROM json_each(CASE WHEN json_valid(new.labels) THEN new.labels ELSE '[]' END) je;
    END;
    CREATE TRIGGER threads_labels_au AFTER UPDATE OF labels, last_msg_at ON threads
    WHEN old.labels IS NOT new.labels OR old.last_msg_at IS NOT new.last_msg_at
    BEGIN
        DELETE FROM thread_labels WHERE thread_id = old.id;
        INSERT OR IGNORE INTO thread_labels (label_id, last_msg_at, thread_id)
        SELECT je.value, new.last_msg_at, new.id
          FROM json_each(CASE WHEN json_valid(new.labels) THEN new.labels ELSE '[]' END) je;
    END;
    CREATE TRIGGER threads_labels_ad AFTER DELETE ON threads BEGIN
        DELETE FROM thread_labels WHERE thread_id = old.id;
    END;
    INSERT OR IGNORE INTO thread_labels (label_id, last_msg_at, thread_id)
    SELECT je.value, t.last_msg_at, t.id
      FROM threads t,
           json_each(CASE WHEN json_valid(t.labels) THEN t.labels ELSE '[]' END) je;
    ",
    // v25 — the passes that run after every sync round ask "which threads
    // are stale" (never scanned for anchors, never triaged, or grown
    // since), newest first. With nothing stale that read the whole table
    // to find nothing, every round. These hold only the stale rows; the
    // WHERE clauses repeat the queries' own text, which is what lets
    // SQLite use them.
    "
    CREATE INDEX idx_threads_anchors_stale ON threads (last_msg_at DESC)
        WHERE anchors_msg_count IS NULL OR anchors_msg_count != msg_count;
    CREATE INDEX idx_threads_triage_stale ON threads (last_msg_at DESC)
        WHERE triage_msg_count IS NULL OR triage_msg_count != msg_count;
    ",
];

/// Schema version whose upgrade re-derives every thread's list sender.
const HEAL_LIST_SENDERS_AT: usize = 17;

/// How long a connection waits for a lock SQLite holds elsewhere (a
/// checkpoint, the other connection's write) before giving up.
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);
/// Reader connections for a database file.
const READERS: usize = 3;
/// Prepared statements each connection keeps. The same few dozen queries
/// run over and over; parsing and planning one cost more than running it.
const STATEMENT_CACHE: usize = 64;

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
/// Mail still waiting in the inbox: not done, not deleted. The Scheduled
/// and Need reply lists hold only these.
const INBOX_SQL: &str = "is_inbox = 1 AND is_archived = 0";

fn thread_filter_sql<'a>(filter: &'a ThreadFilter, label_bind: &str) -> (String, Option<&'a str>) {
    let has = |label: &str| has_label_sql("threads.labels", label);
    let not_junk = not_junk_sql("threads.labels");
    match filter {
        // Flag-based, not label-based: the optimistic local apply flips
        // the flags instantly, before any provider round-trip.
        // A thread with a reminder (due or not) or flagged "needs reply"
        // lives in the Scheduled / Need reply lists instead of the inbox
        // (list and unread badge), until the flag is cleared or the thread
        // is done. It stays in All mail.
        ThreadFilter::Inbox => (
            format!("{INBOX_SQL} AND scheduled_at IS NULL AND needs_reply = 0"),
            None,
        ),
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

/// The page query for one `ThreadFilter` and the label id it binds as ?4
/// (when it reads a label). Parameters: ?1 account (or NULL), ?2 `before`
/// (or NULL), ?3 limit. Keyset pagination — never OFFSET (DESIGN.md).
/// Three shapes, by which index gives the page its newest-first order.
fn list_threads_sql(filter: &ThreadFilter) -> (String, Option<&str>) {
    let not_junk = not_junk_sql("t.labels");
    let has_trash = has_label_sql("t.labels", "TRASH");
    // - a label's views read that label's range of `thread_labels`;
    //   the rest of the rule (junk stays out) is checked on the few
    //   rows that range yields.
    let by_label = |label, rest: String| -> (String, Option<&str>) {
        (
            format!(
                "SELECT {cols} FROM thread_labels tl
                  CROSS JOIN threads t ON t.id = tl.thread_id
                  WHERE tl.label_id = ?4
                    AND (?2 IS NULL OR tl.last_msg_at < ?2)
                    AND ({rest})
                    AND (?1 IS NULL OR t.account_id = ?1)
                  ORDER BY tl.last_msg_at DESC
                  LIMIT ?3",
                cols = thread_cols("t.")
            ),
            Some(label),
        )
    };
    // - the flag views (inbox, archive) and All mail read `threads`
    //   through `idx_threads_list` / `idx_threads_time`.
    let by_flags = |cond: String| -> (String, Option<&str>) {
        (
            format!(
                "SELECT {cols} FROM threads t
                  WHERE ({cond})
                    AND (?1 IS NULL OR t.account_id = ?1)
                    AND (?2 IS NULL OR t.last_msg_at < ?2)
                  ORDER BY t.last_msg_at DESC
                  LIMIT ?3",
                cols = thread_cols("t.")
            ),
            None,
        )
    };
    // Keep in lockstep with `thread_filter_sql` and
    // `ThreadFilter::matches`.
    match filter {
        ThreadFilter::Inbox => by_flags(
            "t.is_inbox = 1 AND t.is_archived = 0
             AND t.scheduled_at IS NULL AND t.needs_reply = 0"
                .to_string(),
        ),
        // Most mail is archived, so walking `idx_threads_time` fills a
        // page within a few rows.
        ThreadFilter::Archive => by_flags("t.is_archived = 1".to_string()),
        ThreadFilter::All => by_flags(not_junk),
        ThreadFilter::Starred => by_label("STARRED", not_junk),
        ThreadFilter::Sent => by_label("SENT", not_junk),
        ThreadFilter::Drafts => by_label("DRAFT", format!("NOT {has_trash}")),
        ThreadFilter::Spam => by_label("SPAM", "1".to_string()),
        ThreadFilter::Trash => by_label("TRASH", "1".to_string()),
        ThreadFilter::Label(id) => by_label(id.as_str(), not_junk),
    }
}

/// "Never scanned for anchors, or grown since". The same text as
/// `idx_threads_anchors_stale`'s WHERE clause: SQLite uses a partial
/// index only for a query that repeats its condition.
const ANCHORS_STALE_SQL: &str = "anchors_msg_count IS NULL OR anchors_msg_count != msg_count";
/// "Never triaged, or grown since" (`idx_threads_triage_stale`).
const TRIAGE_STALE_SQL: &str = "triage_msg_count IS NULL OR triage_msg_count != msg_count";

fn needing_anchors_sql() -> String {
    format!(
        "SELECT {THREAD_COLS} FROM threads
          WHERE {ANCHORS_STALE_SQL}
          ORDER BY last_msg_at DESC
          LIMIT ?1"
    )
}

fn needing_triage_sql() -> String {
    format!(
        "SELECT {THREAD_COLS} FROM threads
          WHERE {TRIAGE_STALE_SQL}
          ORDER BY last_msg_at DESC
          LIMIT ?1"
    )
}

fn count_needing_triage_sql() -> String {
    format!(
        "SELECT COUNT(*) FROM threads
          WHERE ({TRIAGE_STALE_SQL})
            AND last_msg_at >= ?1"
    )
}

pub struct SqliteStore {
    /// Every write, and the background passes' own queries.
    conn: Mutex<Connection>,
    /// The reads (`read`): more connections to the same file. Empty for an
    /// in-memory store, where another connection would be another
    /// database; its reads use `conn`.
    readers: Vec<Mutex<Connection>>,
    /// Which reader a read waits for when all are busy (round robin).
    next_reader: AtomicUsize,
}

fn err(e: impl std::fmt::Display) -> StoreError {
    StoreError(e.to_string())
}

/// Per-connection settings: a page cache of `cache_kib` (SQLite's default
/// is 2 MB, a fraction of a real mailbox's index), sorts and other
/// temporaries in memory, and room for the statements `prepare_cached`
/// keeps.
fn tune(conn: &Connection, cache_kib: i64) -> rusqlite::Result<()> {
    conn.pragma_update(None, "cache_size", -cache_kib)?;
    conn.pragma_update(None, "temp_store", "MEMORY")?;
    conn.set_prepared_statement_cache_capacity(STATEMENT_CACHE);
    Ok(())
}

/// One-time v17 heal: rewrite every thread's `from_summary` /
/// `last_from_addr` with `sync::list_sender` over its stored messages, so
/// a thread the user replied to names the other party however old it is.
/// Threads without cached messages are left for the next provider upsert.
fn heal_list_senders(conn: &Connection) -> rusqlite::Result<()> {
    let emails: HashMap<String, String> = conn
        .prepare("SELECT id, email FROM accounts")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let threads: Vec<(String, String)> = conn
        .prepare("SELECT id, account_id FROM threads")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let mut messages = conn.prepare(
        "SELECT from_addr, to_addrs, label_ids FROM messages WHERE thread_id = ?1 ORDER BY date",
    )?;
    let mut update =
        conn.prepare("UPDATE threads SET from_summary = ?1, last_from_addr = ?2 WHERE id = ?3")?;
    let mut healed = 0usize;
    for (thread_id, account_id) in &threads {
        let msgs: Vec<Message> = messages
            .query_map(params![thread_id], |r| {
                let to_addrs: String = r.get(1)?;
                let label_ids: String = r.get(2)?;
                Ok(Message {
                    id: String::new(),
                    thread_id: thread_id.clone(),
                    account_id: account_id.clone(),
                    from_addr: r.get(0)?,
                    to_addrs: serde_json::from_str(&to_addrs).unwrap_or_default(),
                    date: 0,
                    snippet: String::new(),
                    body_html: None,
                    body_text: None,
                    label_ids: serde_json::from_str(&label_ids).unwrap_or_default(),
                    is_read: true,
                    ..Default::default()
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        if msgs.is_empty() {
            continue;
        }
        let own_email = emails.get(account_id).unwrap_or(account_id);
        let sender = heypigeon_core::sync::list_sender(&msgs, own_email);
        update.execute(params![sender.name, sender.addr, thread_id])?;
        healed += 1;
    }
    log::info!("v17: re-derived list sender on {healed} threads");
    Ok(())
}

impl SqliteStore {
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        let conn = Connection::open(path).map_err(err)?;
        let mut store = Self::init(conn)?;
        // Opened after the migrations, so they see the finished schema.
        for _ in 0..READERS {
            let reader = Connection::open(path).map_err(err)?;
            reader.busy_timeout(BUSY_TIMEOUT).map_err(err)?;
            // A reader that writes would be a second writer.
            reader
                .pragma_update(None, "query_only", "ON")
                .map_err(err)?;
            tune(&reader, 4_000).map_err(err)?;
            store.readers.push(Mutex::new(reader));
        }
        Ok(store)
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
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(err)?;
        // A commit no longer waits for the WAL to reach the disk (the
        // checkpoint does): a sync page is hundreds of small writes, not
        // hundreds of fsyncs. A power cut costs at most the last commits,
        // never consistency, and the database is a cache.
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(err)?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(err)?;
        conn.busy_timeout(BUSY_TIMEOUT).map_err(err)?;
        tune(&conn, 8_000).map_err(err)?;
        let version: i64 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(err)?;
        for (i, migration) in MIGRATIONS
            .iter()
            .enumerate()
            .take(target)
            .skip(version as usize)
        {
            // One transaction per step, version bump included: a step is
            // several statements, and an app killed halfway through one
            // (the label table's backfill takes a moment on a big mailbox)
            // must find the database at the old version, not half changed
            // — the next launch would fail on "duplicate column" for good.
            let tx = conn.unchecked_transaction().map_err(err)?;
            tx.execute_batch(migration).map_err(err)?;
            if i + 1 == HEAL_LIST_SENDERS_AT {
                heal_list_senders(&tx).map_err(err)?;
            }
            tx.pragma_update(None, "user_version", i as i64 + 1)
                .map_err(err)?;
            tx.commit().map_err(err)?;
        }
        Ok(Self {
            conn: Mutex::new(conn),
            readers: Vec::new(),
            next_reader: AtomicUsize::new(0),
        })
    }

    /// The writer connection: every write, and the background passes' reads.
    fn with<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|_| StoreError("lock poisoned".into()))?;
        f(&conn).map_err(err)
    }

    /// A reader connection, for reads: it sees every commit (WAL readers
    /// start from the latest one) and never waits for a write in progress.
    /// The first one that is free; when all are busy, the next in turn.
    /// The writer itself for an in-memory store.
    fn read<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, StoreError> {
        if self.readers.is_empty() {
            return self.with(f);
        }
        for reader in &self.readers {
            if let Ok(conn) = reader.try_lock() {
                return f(&conn).map_err(err);
            }
        }
        let turn = self.next_reader.fetch_add(1, Ordering::Relaxed) % self.readers.len();
        let conn = self.readers[turn]
            .lock()
            .map_err(|_| StoreError("lock poisoned".into()))?;
        f(&conn).map_err(err)
    }

    /// Add/remove one label in the thread's labels JSON union. is_inbox /
    /// is_archived stay untouched — label flips never move mail between the
    /// flag-driven folders (Archive/Trash own those).
    fn flip_label(
        &self,
        thread_id: &ThreadId,
        label_id: &str,
        add: bool,
    ) -> Result<(), StoreError> {
        let Some(mut t) = self.get_thread(thread_id)? else {
            return Err(StoreError(format!("unknown thread {thread_id}")));
        };
        t.labels.retain(|l| l != label_id);
        if add {
            t.labels.push(label_id.to_string());
        }
        let labels = serde_json::to_string(&t.labels).map_err(err)?;
        self.with(|c| {
            c.execute(
                "UPDATE threads SET labels = ?2 WHERE id = ?1",
                params![thread_id, labels],
            )
        })?;
        Ok(())
    }

    /// Every scheduled thread still in the inbox, past the inbox page
    /// limit too (the inbox list itself leaves them out). Done mail has no
    /// reminder: archiving clears it (`devsync::clear_on_done`), and this
    /// filter covers mail archived elsewhere, e.g. in Gmail.
    pub fn list_scheduled(&self) -> Result<Vec<Thread>, StoreError> {
        self.read(|c| {
            let mut stmt = c.prepare_cached(&format!(
                "SELECT {THREAD_COLS} FROM threads
                 WHERE scheduled_at IS NOT NULL AND {INBOX_SQL}
                 ORDER BY scheduled_at ASC"
            ))?;
            let rows = stmt.query_map([], row_to_thread)?;
            rows.collect()
        })
    }

    /// Every thread flagged "needs reply" still in the inbox — same rules
    /// as `list_scheduled`. Newest first, matching the inbox's natural
    /// order.
    pub fn list_needs_reply(&self) -> Result<Vec<Thread>, StoreError> {
        self.read(|c| {
            let mut stmt = c.prepare_cached(&format!(
                "SELECT {THREAD_COLS} FROM threads
                 WHERE needs_reply = 1 AND {INBOX_SQL}
                 ORDER BY last_msg_at DESC"
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
            tx.execute(
                "DELETE FROM outbox WHERE account_id = ?1",
                params![account_id],
            )?;
            tx.execute(
                "DELETE FROM sync_kv WHERE account_id = ?1",
                params![account_id],
            )?;
            tx.execute(
                "DELETE FROM sync_meta WHERE account_id = ?1",
                params![account_id],
            )?;
            tx.execute(
                "DELETE FROM messages WHERE account_id = ?1",
                params![account_id],
            )?;
            tx.execute(
                "DELETE FROM thread_anchors WHERE thread_id IN
                   (SELECT id FROM threads WHERE account_id = ?1)",
                params![account_id],
            )?;
            tx.execute(
                "DELETE FROM threads WHERE account_id = ?1",
                params![account_id],
            )?;
            tx.execute(
                "DELETE FROM labels WHERE account_id = ?1",
                params![account_id],
            )?;
            tx.execute("DELETE FROM accounts WHERE id = ?1", params![account_id])?;
            tx.commit()
        })
    }

    /// Add (or rename) one label row: a label just created at the provider
    /// shows in the sidebar without waiting for the next `set_labels`.
    pub fn upsert_label(&self, label: &Label) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "INSERT INTO labels (account_id, id, name) VALUES (?1, ?2, ?3)
                 ON CONFLICT(account_id, id) DO UPDATE SET name = excluded.name",
                params![label.account_id, label.id, label.name],
            )
            .map(|_| ())
        })
    }

    /// Who the stored mail is from and to, for recipient suggestions: one
    /// row per distinct (From, To, Cc, sent-by-the-user) combination with
    /// how many messages carry it and the newest one's date. The address
    /// lists are returned as stored (JSON arrays of header entries).
    pub fn correspondents(&self) -> Result<Vec<Correspondence>, StoreError> {
        self.read(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT from_addr, to_addrs, cc_addrs,
                        instr(label_ids, '\"SENT\"') > 0 AS sent,
                        COUNT(*), MAX(date)
                   FROM messages
                  GROUP BY from_addr, to_addrs, cc_addrs, sent",
            )?;
            let rows = stmt.query_map([], |r| {
                let to: String = r.get(1)?;
                let cc: String = r.get(2)?;
                Ok(Correspondence {
                    from_addr: r.get(0)?,
                    to_addrs: serde_json::from_str(&to).unwrap_or_default(),
                    cc_addrs: serde_json::from_str(&cc).unwrap_or_default(),
                    sent: r.get(3)?,
                    count: r.get(4)?,
                    last_at: r.get(5)?,
                })
            })?;
            rows.collect()
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

/// One row of `SqliteStore::correspondents`.
#[derive(Debug, Clone, PartialEq)]
pub struct Correspondence {
    pub from_addr: String,
    pub to_addrs: Vec<String>,
    pub cc_addrs: Vec<String>,
    /// The user sent these messages (Gmail's SENT label).
    pub sent: bool,
    pub count: i64,
    /// Epoch ms of the newest message of the group.
    pub last_at: i64,
}

/// The message columns, in `row_to_message`'s order.
const MESSAGE_COLS: &str = "id, thread_id, account_id, from_addr, to_addrs, date, snippet, \
     body_html, body_text, label_ids, is_read, cc_addrs, message_id_header, \
     references_header, list_unsubscribe, list_unsubscribe_one_click, body_fetched";

/// `MESSAGE_COLS` without reading the bodies (`Store::list_message_meta`).
const MESSAGE_META_COLS: &str = "id, thread_id, account_id, from_addr, to_addrs, date, snippet, \
     NULL, NULL, label_ids, is_read, cc_addrs, message_id_header, \
     references_header, list_unsubscribe, list_unsubscribe_one_click, body_fetched";

fn row_to_message(r: &rusqlite::Row<'_>) -> rusqlite::Result<Message> {
    let to_addrs: String = r.get(4)?;
    let label_ids: String = r.get(9)?;
    let cc_addrs: String = r.get(11)?;
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
        cc_addrs: serde_json::from_str(&cc_addrs).unwrap_or_default(),
        message_id_header: r.get(12)?,
        references_header: r.get(13)?,
        list_unsubscribe: r.get(14)?,
        list_unsubscribe_one_click: r.get(15)?,
        body_fetched: r.get(16)?,
    })
}

fn row_to_outbox_item(r: &rusqlite::Row<'_>) -> rusqlite::Result<OutboxItem> {
    let payload: String = r.get(2)?;
    Ok(OutboxItem {
        id: r.get(0)?,
        account_id: r.get(1)?,
        mutation: serde_json::from_str(&payload).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, Box::new(e))
        })?,
        attempts: r.get(3)?,
        created_at: r.get(4)?,
    })
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
        priority: r
            .get::<_, Option<String>>(14)?
            .and_then(|s| Priority::parse(&s)),
        triage_label_ids: serde_json::from_str(&r.get::<_, String>(15)?).unwrap_or_default(),
        needs_reply: r.get(16)?,
        follow_up_since: r.get(17)?,
        suggestion: r
            .get::<_, Option<String>>(18)?
            .and_then(|s| serde_json::from_str(&s).ok()),
        bundle_id: r.get(19)?,
    })
}

/// `upsert_thread` on a given connection: the store's, or a transaction's
/// for a whole page (`upsert_page`).
fn upsert_thread_on(c: &Connection, t: &Thread) -> rusqlite::Result<()> {
    let labels = serde_json::to_string(&t.labels)
        .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    // scheduled_at is deliberately absent from the column list AND the
    // UPDATE set: it is local-only metadata (never synced to Gmail), so a
    // sync re-upsert of provider data must not clobber an existing schedule.
    // Writes go through `set_schedule` only. labels, by contrast, ARE
    // provider data — re-upserts must write them so the folder queries stay
    // current.
    c.prepare_cached(
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
    )?
    .execute(params![
        t.id,
        t.account_id,
        t.subject,
        t.snippet,
        t.last_msg_at,
        t.is_read,
        t.is_inbox,
        t.is_archived,
        t.msg_count,
        t.from_summary,
        t.last_from_addr,
        labels,
        t.has_attachment
    ])?;
    Ok(())
}

/// `upsert_message` on a given connection (see `upsert_thread_on`).
fn upsert_message_on(c: &Connection, m: &Message) -> rusqlite::Result<()> {
    let json = |v: &[String]| {
        serde_json::to_string(v).map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))
    };
    let to_addrs = json(&m.to_addrs)?;
    let cc_addrs = json(&m.cc_addrs)?;
    let label_ids = json(&m.label_ids)?;
    c.prepare_cached(
        "INSERT INTO messages
           (id, thread_id, account_id, from_addr, to_addrs, date, snippet,
            body_html, body_text, label_ids, is_read, cc_addrs, message_id_header,
            references_header, list_unsubscribe, list_unsubscribe_one_click, body_fetched)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
         ON CONFLICT(id) DO UPDATE SET
           snippet = excluded.snippet,
           -- bodies fetch lazily; a metadata-tier re-upsert (backfill,
           -- delta thread refetch) must not wipe them
           body_html = COALESCE(excluded.body_html, body_html),
           body_text = COALESCE(excluded.body_text, body_text),
           label_ids = excluded.label_ids,
           is_read = excluded.is_read,
           -- a message's headers never change: an upsert that does not
           -- carry one (a row read without it and written back) keeps it
           cc_addrs = CASE WHEN excluded.cc_addrs = '[]' THEN cc_addrs
                           ELSE excluded.cc_addrs END,
           message_id_header = COALESCE(excluded.message_id_header, message_id_header),
           references_header = COALESCE(excluded.references_header, references_header),
           list_unsubscribe = COALESCE(excluded.list_unsubscribe, list_unsubscribe),
           list_unsubscribe_one_click =
               MAX(list_unsubscribe_one_click, excluded.list_unsubscribe_one_click),
           -- once fetched in full, always: only a full fetch sets it
           body_fetched = MAX(body_fetched, excluded.body_fetched)",
    )?
    .execute(params![
        m.id,
        m.thread_id,
        m.account_id,
        m.from_addr,
        to_addrs,
        m.date,
        m.snippet,
        m.body_html,
        m.body_text,
        label_ids,
        m.is_read,
        cc_addrs,
        m.message_id_header,
        m.references_header,
        m.list_unsubscribe,
        m.list_unsubscribe_one_click,
        m.body_fetched
    ])?;
    Ok(())
}

const THREAD_COLS: &str =
    "id, account_id, subject, snippet, last_msg_at, is_read, is_inbox, is_archived, msg_count, from_summary, last_from_addr, scheduled_at, labels, has_attachment, priority, triage_label_ids, needs_reply, follow_up_since, suggestion, bundle_id";

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
        self.read(|c| {
            let mut stmt =
                c.prepare_cached("SELECT id, email, display_name, color, history_id, avatar_url, signature FROM accounts ORDER BY id")?;
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
        self.with(|c| upsert_thread_on(c, t))
    }

    fn upsert_message(&self, m: &Message) -> Result<(), StoreError> {
        self.with(|c| upsert_message_on(c, m))
    }

    fn upsert_thread_with_messages(
        &self,
        thread: &Thread,
        messages: &[Message],
    ) -> Result<(), StoreError> {
        self.with(|c| {
            let tx = c.unchecked_transaction()?;
            upsert_thread_on(&tx, thread)?;
            for m in messages {
                upsert_message_on(&tx, m)?;
            }
            tx.commit()
        })
    }

    /// One transaction for the page: one commit, one turn of the lock.
    fn upsert_page(&self, page: &[(Thread, Vec<Message>)]) -> Result<(), StoreError> {
        self.with(|c| {
            let tx = c.unchecked_transaction()?;
            for (thread, messages) in page {
                upsert_thread_on(&tx, thread)?;
                for m in messages {
                    upsert_message_on(&tx, m)?;
                }
            }
            tx.commit()
        })
    }

    fn delete_message(&self, message_id: &MessageId) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute("DELETE FROM messages WHERE id = ?1", params![message_id])
                .map(|_| ())
        })
    }

    fn delete_thread(&self, thread_id: &ThreadId) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "DELETE FROM messages WHERE thread_id = ?1",
                params![thread_id],
            )?;
            c.execute(
                "DELETE FROM thread_anchors WHERE thread_id = ?1",
                params![thread_id],
            )?;
            c.execute("DELETE FROM threads WHERE id = ?1", params![thread_id])
                .map(|_| ())
        })
    }

    fn list_threads(
        &self,
        account_id: Option<&AccountId>,
        filter: &ThreadFilter,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<Thread>, StoreError> {
        let (sql, label_param) = list_threads_sql(filter);
        self.read(|c| {
            let mut stmt = c.prepare_cached(&sql)?;
            let rows = match label_param {
                Some(id) => {
                    stmt.query_map(params![account_id, before, limit, id], row_to_thread)?
                }
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
        self.read(|c| {
            let sql = format!(
                "SELECT COUNT(*) FROM threads
                 WHERE ({cond}) AND is_read = 0
                   AND (?1 IS NULL OR account_id = ?1)"
            );
            let mut stmt = c.prepare_cached(&sql)?;
            match label_param {
                Some(id) => stmt.query_row(params![account_id, id], |r| r.get(0)),
                None => stmt.query_row(params![account_id], |r| r.get(0)),
            }
        })
    }

    /// One pass over the unread rows, classified in Rust
    /// (`ThreadFilter::matches`), instead of a scan of the whole table per
    /// folder and per label with `json_each` on every row. The shells ask
    /// for these after every reload, so the pass reads only what the
    /// folder rules look at — the labels and four flags — and groups equal
    /// rows in SQL: thousands of unread newsletters are a handful of label
    /// sets, each parsed and classified once. (It used to build every
    /// unread thread in full, subject and snippet included.)
    fn unread_counts(
        &self,
        account_id: Option<&AccountId>,
    ) -> Result<HashMap<String, i64>, StoreError> {
        let labels = self.list_labels()?;
        let unread: Vec<(Thread, i64)> = self.read(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT labels, is_inbox, is_archived, scheduled_at IS NOT NULL AS scheduled,
                        needs_reply, COUNT(*)
                   FROM threads
                  WHERE is_read = 0 AND (?1 IS NULL OR account_id = ?1)
                  GROUP BY labels, is_inbox, is_archived, scheduled, needs_reply",
            )?;
            let rows = stmt.query_map(params![account_id], |r| {
                let scheduled: bool = r.get(3)?;
                Ok((
                    Thread {
                        labels: serde_json::from_str(&r.get::<_, String>(0)?).unwrap_or_default(),
                        is_inbox: r.get(1)?,
                        is_archived: r.get(2)?,
                        // Only "has a reminder" matters to the folder rules.
                        scheduled_at: scheduled.then_some(0),
                        needs_reply: r.get(4)?,
                        ..Thread::default()
                    },
                    r.get(5)?,
                ))
            })?;
            rows.collect()
        })?;
        let count = |filter: &ThreadFilter| -> i64 {
            unread
                .iter()
                .filter(|(t, _)| filter.matches(t))
                .map(|(_, n)| n)
                .sum()
        };
        let mut out = HashMap::new();
        for (key, filter) in ThreadFilter::COUNTED_FOLDERS {
            out.insert(key.to_string(), count(&filter));
        }
        for label in labels {
            out.insert(
                format!("label:{}", label.id),
                count(&ThreadFilter::Label(label.id)),
            );
        }
        Ok(out)
    }

    fn set_labels(&self, account_id: &AccountId, labels: &[Label]) -> Result<(), StoreError> {
        self.with(|c| {
            // Wholesale replace: labels deleted upstream must disappear.
            c.execute(
                "DELETE FROM labels WHERE account_id = ?1",
                params![account_id],
            )?;
            let mut stmt =
                c.prepare_cached("INSERT INTO labels (account_id, id, name) VALUES (?1, ?2, ?3)")?;
            for l in labels {
                stmt.execute(params![account_id, l.id, l.name])?;
            }
            Ok(())
        })
    }

    fn list_labels(&self) -> Result<Vec<Label>, StoreError> {
        self.read(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT account_id, id, name FROM labels
                 ORDER BY name COLLATE NOCASE, account_id",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok(Label {
                    account_id: r.get(0)?,
                    id: r.get(1)?,
                    name: r.get(2)?,
                })
            })?;
            rows.collect()
        })
    }

    fn list_triage_labels(&self) -> Result<Vec<TriageLabel>, StoreError> {
        self.read(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT id, name FROM triage_labels ORDER BY name COLLATE NOCASE",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok(TriageLabel {
                    id: r.get(0)?,
                    name: r.get(1)?,
                })
            })?;
            rows.collect()
        })
    }

    fn create_triage_label(&self, name: &str) -> Result<TriageLabel, StoreError> {
        let exists = self.with(|c| {
            c.query_row(
                "SELECT 1 FROM triage_labels WHERE name = ?1",
                params![name],
                |_| Ok(()),
            )
            .optional()
        })?;
        if exists.is_some() {
            return Err(StoreError(format!("triage label '{name}' already exists")));
        }
        self.with(|c| {
            // Random id, not a counter: labels sync between devices by id
            // (see the v15 migration note).
            let id: String = c.query_row(
                "INSERT INTO triage_labels (id, name) VALUES (lower(hex(randomblob(16))), ?1)
                 RETURNING id",
                params![name],
                |r| r.get(0),
            )?;
            // A new label may match mail already synced, not just future
            // mail — make every thread stale so the poller (bounded by its
            // own per-tick cap) gradually reclassifies existing inboxes too.
            c.execute("UPDATE threads SET triage_msg_count = NULL", [])?;
            Ok(TriageLabel {
                id,
                name: name.to_string(),
            })
        })
    }

    /// Cross-device apply: insert under the remote id or rename in place.
    /// A brand-new row invalidates triage like `create_triage_label`.
    fn upsert_triage_label(&self, label: &TriageLabel) -> Result<(), StoreError> {
        self.with(|c| {
            let tx = c.unchecked_transaction()?;
            let existed = tx
                .query_row(
                    "SELECT 1 FROM triage_labels WHERE id = ?1",
                    params![label.id],
                    |_| Ok(()),
                )
                .optional()?
                .is_some();
            tx.execute(
                "INSERT INTO triage_labels (id, name) VALUES (?1, ?2)
                 ON CONFLICT(id) DO UPDATE SET name = excluded.name",
                params![label.id, label.name],
            )?;
            if !existed {
                tx.execute("UPDATE threads SET triage_msg_count = NULL", [])?;
            }
            tx.commit()
        })
    }

    fn clear_manual_triage_labels(&self, thread_id: &ThreadId) -> Result<bool, StoreError> {
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET triage_labels_manual = 0, triage_msg_count = NULL WHERE id = ?1",
                params![thread_id],
            )
        })?;
        Ok(n > 0)
    }

    fn get_pref(&self, name: &str) -> Result<Option<serde_json::Value>, StoreError> {
        let raw: Option<String> = self.read(|c| {
            c.query_row(
                "SELECT value FROM prefs WHERE name = ?1",
                params![name],
                |r| r.get(0),
            )
            .optional()
        })?;
        raw.map(|v| serde_json::from_str(&v).map_err(err))
            .transpose()
    }

    fn set_pref(&self, name: &str, value: Option<&serde_json::Value>) -> Result<(), StoreError> {
        match value {
            Some(v) => {
                let raw = serde_json::to_string(v).map_err(err)?;
                self.with(|c| {
                    c.execute(
                        "INSERT INTO prefs (name, value) VALUES (?1, ?2)
                         ON CONFLICT(name) DO UPDATE SET value = excluded.value",
                        params![name, raw],
                    )
                    .map(|_| ())
                })
            }
            None => self.with(|c| {
                c.execute("DELETE FROM prefs WHERE name = ?1", params![name])
                    .map(|_| ())
            }),
        }
    }

    fn list_prefs(&self) -> Result<Vec<(String, serde_json::Value)>, StoreError> {
        let rows: Vec<(String, String)> = self.read(|c| {
            let mut stmt = c.prepare_cached("SELECT name, value FROM prefs ORDER BY name")?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect()
        })?;
        rows.into_iter()
            .map(|(n, v)| Ok((n, serde_json::from_str(&v).map_err(err)?)))
            .collect()
    }

    /// Same invalidation `create_triage_label` does, exposed directly for
    /// Settings' explicit "Reanalyze all emails" action. Also clears any
    /// manual label pins — an explicit full reanalysis should let Jev take
    /// another pass rather than staying blocked by an old manual edit.
    fn reset_triage(&self) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "UPDATE threads SET triage_msg_count = NULL, triage_labels_manual = 0",
                [],
            )
            .map(|_| ())
        })
    }

    fn list_bundles(&self) -> Result<Vec<Bundle>, StoreError> {
        self.read(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT id, name, kind, description, status, created_at, updated_at, origin
                   FROM bundles
                  ORDER BY status = 'archived', name COLLATE NOCASE",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok(Bundle {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    kind: BundleKind::parse(&r.get::<_, String>(2)?),
                    description: r.get(3)?,
                    status: BundleStatus::parse(&r.get::<_, String>(4)?),
                    origin: BundleOrigin::parse(&r.get::<_, String>(7)?),
                    created_at: r.get(5)?,
                    updated_at: r.get(6)?,
                })
            })?;
            rows.collect()
        })
    }

    fn upsert_bundle(&self, b: &Bundle) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "INSERT INTO bundles (id, name, kind, description, status, created_at, updated_at, origin)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(id) DO UPDATE SET
                   name = excluded.name, kind = excluded.kind,
                   description = excluded.description, status = excluded.status,
                   updated_at = excluded.updated_at, origin = excluded.origin",
                params![
                    b.id,
                    b.name,
                    b.kind.as_str(),
                    b.description,
                    b.status.as_str(),
                    b.created_at,
                    b.updated_at,
                    b.origin.as_str()
                ],
            )
            .map(|_| ())
        })
    }

    fn delete_bundle(&self, id: &str) -> Result<(), StoreError> {
        self.with(|c| {
            let tx = c.unchecked_transaction()?;
            tx.execute(
                "UPDATE threads SET bundle_id = NULL, bundle_source = NULL WHERE bundle_id = ?1",
                params![id],
            )?;
            tx.execute(
                "DELETE FROM bundle_exclusions WHERE bundle_id = ?1",
                params![id],
            )?;
            tx.execute("DELETE FROM bundles WHERE id = ?1", params![id])?;
            tx.commit()
        })
    }

    fn set_thread_bundle(
        &self,
        thread_id: &ThreadId,
        bundle: Option<(&str, BundleSource)>,
    ) -> Result<bool, StoreError> {
        let (id, source) = match bundle {
            Some((id, source)) => (Some(id), Some(source.as_str())),
            None => (None, None),
        };
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET bundle_id = ?2, bundle_source = ?3 WHERE id = ?1",
                params![thread_id, id, source],
            )
        })?;
        Ok(n > 0)
    }

    fn thread_bundle_source(
        &self,
        thread_id: &ThreadId,
    ) -> Result<Option<BundleSource>, StoreError> {
        let source: Option<String> = self.with(|c| {
            c.query_row(
                "SELECT bundle_source FROM threads WHERE id = ?1 AND bundle_id IS NOT NULL",
                params![thread_id],
                |r| r.get(0),
            )
            .optional()
            .map(Option::flatten)
        })?;
        Ok(source.map(|s| BundleSource::parse(&s)))
    }

    fn exclude_from_bundle(&self, bundle_id: &str, thread_id: &ThreadId) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "INSERT OR IGNORE INTO bundle_exclusions (bundle_id, thread_id) VALUES (?1, ?2)",
                params![bundle_id, thread_id],
            )
            .map(|_| ())
        })
    }

    fn clear_bundle_exclusion(
        &self,
        bundle_id: &str,
        thread_id: &ThreadId,
    ) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "DELETE FROM bundle_exclusions WHERE bundle_id = ?1 AND thread_id = ?2",
                params![bundle_id, thread_id],
            )
            .map(|_| ())
        })
    }

    fn is_excluded_from_bundle(
        &self,
        bundle_id: &str,
        thread_id: &ThreadId,
    ) -> Result<bool, StoreError> {
        self.with(|c| {
            c.query_row(
                "SELECT 1 FROM bundle_exclusions WHERE bundle_id = ?1 AND thread_id = ?2",
                params![bundle_id, thread_id],
                |_| Ok(()),
            )
            .optional()
            .map(|r| r.is_some())
        })
    }

    fn list_bundle_exclusions(&self, bundle_id: &str) -> Result<Vec<ThreadId>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT thread_id FROM bundle_exclusions WHERE bundle_id = ?1 ORDER BY thread_id",
            )?;
            let rows = stmt.query_map(params![bundle_id], |r| r.get(0))?;
            rows.collect()
        })
    }

    fn list_bundle_threads(&self, bundle_id: &str) -> Result<Vec<Thread>, StoreError> {
        let junk = format!(
            "({} OR {})",
            has_label_sql("labels", "TRASH"),
            has_label_sql("labels", "SPAM")
        );
        self.read(|c| {
            let mut stmt = c.prepare_cached(&format!(
                "SELECT {THREAD_COLS} FROM threads
                  WHERE bundle_id = ?1 AND NOT {junk}
                  ORDER BY last_msg_at DESC"
            ))?;
            let rows = stmt.query_map(params![bundle_id], row_to_thread)?;
            rows.collect()
        })
    }

    /// One grouped query over the bundled threads (`threads_by_bundle`),
    /// trash and spam left out through `thread_labels`.
    fn bundle_stats(&self) -> Result<HashMap<String, BundleStats>, StoreError> {
        self.read(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT t.bundle_id, COUNT(*),
                        SUM(t.is_inbox = 1 AND t.is_archived = 0), MAX(t.last_msg_at)
                   FROM threads t
                  WHERE t.bundle_id IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM thread_labels tl
                                     WHERE tl.thread_id = t.id
                                       AND tl.label_id IN ('TRASH', 'SPAM'))
                  GROUP BY t.bundle_id",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    BundleStats {
                        thread_count: r.get(1)?,
                        open_count: r.get(2)?,
                        last_activity_at: r.get(3)?,
                    },
                ))
            })?;
            rows.collect()
        })
    }

    fn list_threads_needing_anchors(&self, limit: u32) -> Result<Vec<Thread>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare_cached(&needing_anchors_sql())?;
            let rows = stmt.query_map(params![limit], row_to_thread)?;
            rows.collect()
        })
    }

    fn set_thread_anchors(
        &self,
        thread_id: &ThreadId,
        anchors: &[String],
        msg_count: i64,
    ) -> Result<(), StoreError> {
        self.with(|c| {
            let tx = c.unchecked_transaction()?;
            tx.execute(
                "DELETE FROM thread_anchors WHERE thread_id = ?1",
                params![thread_id],
            )?;
            for anchor in anchors {
                tx.execute(
                    "INSERT OR IGNORE INTO thread_anchors (thread_id, anchor) VALUES (?1, ?2)",
                    params![thread_id, anchor],
                )?;
            }
            tx.execute(
                "UPDATE threads SET anchors_msg_count = ?2 WHERE id = ?1",
                params![thread_id, msg_count],
            )?;
            tx.commit()
        })
    }

    /// One transaction for the whole batch (the link pass: up to 500
    /// threads a round, each a commit of its own before).
    fn set_thread_anchors_batch(
        &self,
        items: &[(ThreadId, Vec<String>, i64)],
    ) -> Result<(), StoreError> {
        self.with(|c| {
            let tx = c.unchecked_transaction()?;
            {
                let mut clear =
                    tx.prepare_cached("DELETE FROM thread_anchors WHERE thread_id = ?1")?;
                let mut insert = tx.prepare_cached(
                    "INSERT OR IGNORE INTO thread_anchors (thread_id, anchor) VALUES (?1, ?2)",
                )?;
                let mut stamp =
                    tx.prepare_cached("UPDATE threads SET anchors_msg_count = ?2 WHERE id = ?1")?;
                for (thread_id, anchors, msg_count) in items {
                    clear.execute(params![thread_id])?;
                    for anchor in anchors {
                        insert.execute(params![thread_id, anchor])?;
                    }
                    stamp.execute(params![thread_id, msg_count])?;
                }
            }
            tx.commit()
        })
    }

    fn list_threads_needing_bundling(
        &self,
        since: i64,
        limit: u32,
    ) -> Result<Vec<Thread>, StoreError> {
        let junk = format!(
            "({} OR {} OR {})",
            has_label_sql("labels", "TRASH"),
            has_label_sql("labels", "SPAM"),
            has_label_sql("labels", "DRAFT")
        );
        self.with(|c| {
            let mut stmt = c.prepare_cached(&format!(
                "SELECT {THREAD_COLS} FROM threads
                 WHERE bundle_id IS NULL
                   AND last_msg_at >= ?1
                   AND (bundle_ai_msg_count IS NULL OR bundle_ai_msg_count != msg_count)
                   AND (priority IS NULL OR priority != 'spam')
                   AND NOT {junk}
                 ORDER BY last_msg_at DESC
                 LIMIT ?2"
            ))?;
            let rows = stmt.query_map(params![since, limit], row_to_thread)?;
            rows.collect()
        })
    }

    fn set_thread_bundling_done(
        &self,
        thread_id: &ThreadId,
        msg_count: i64,
    ) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "UPDATE threads SET bundle_ai_msg_count = ?2 WHERE id = ?1",
                params![thread_id, msg_count],
            )
            .map(|_| ())
        })
    }

    fn thread_anchors(&self, thread_id: &ThreadId) -> Result<Vec<String>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT anchor FROM thread_anchors WHERE thread_id = ?1 ORDER BY anchor",
            )?;
            let rows = stmt.query_map(params![thread_id], |r| r.get(0))?;
            rows.collect()
        })
    }

    fn threads_with_anchors(
        &self,
        anchors: &[String],
    ) -> Result<Vec<(ThreadId, Vec<String>)>, StoreError> {
        if anchors.is_empty() {
            return Ok(Vec::new());
        }
        let list = serde_json::to_string(anchors).map_err(err)?;
        let pairs: Vec<(String, String)> = self.with(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT thread_id, anchor FROM thread_anchors
                  WHERE anchor IN (SELECT value FROM json_each(?1))
                  ORDER BY thread_id, anchor",
            )?;
            let rows = stmt.query_map(params![list], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect()
        })?;
        let mut out: Vec<(ThreadId, Vec<String>)> = Vec::new();
        for (thread, anchor) in pairs {
            match out.last_mut() {
                Some((t, a)) if *t == thread => a.push(anchor),
                _ => out.push((thread, vec![anchor])),
            }
        }
        Ok(out)
    }

    fn rename_triage_label(&self, id: &str, new_name: &str) -> Result<(), StoreError> {
        let n = self.with(|c| {
            c.execute(
                "UPDATE triage_labels SET name = ?2 WHERE id = ?1",
                params![id, new_name],
            )
        })?;
        if n == 0 {
            return Err(StoreError(format!("unknown triage label {id}")));
        }
        Ok(())
    }

    /// Remove a triage category locally: drop the row AND strip the id from
    /// every thread's `triage_label_ids` JSON array — mirrors `delete_label`.
    fn delete_triage_label(&self, id: &str) -> Result<(), StoreError> {
        self.with(|c| {
            let tx = c.unchecked_transaction()?;
            tx.execute("DELETE FROM triage_labels WHERE id = ?1", params![id])?;
            tx.execute(
                "UPDATE threads SET triage_label_ids =
                    (SELECT json_group_array(value) FROM json_each(threads.triage_label_ids)
                     WHERE value <> ?1)
                 WHERE EXISTS (SELECT 1 FROM json_each(threads.triage_label_ids) WHERE value = ?1)",
                params![id],
            )?;
            tx.commit()
        })
    }

    fn list_threads_needing_triage(&self, limit: u32) -> Result<Vec<Thread>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare_cached(&needing_triage_sql())?;
            let rows = stmt.query_map(params![limit], row_to_thread)?;
            rows.collect()
        })
    }

    fn count_threads_needing_triage(&self, since: i64) -> Result<u32, StoreError> {
        // Same filter as `list_threads_needing_triage`, plus the window.
        self.with(|c| c.query_row(&count_needing_triage_sql(), params![since], |r| r.get(0)))
    }

    fn list_threads_needing_suggestion(
        &self,
        since: i64,
        limit: u32,
    ) -> Result<Vec<Thread>, StoreError> {
        // Keep in lockstep with MemStore's filter.
        self.with(|c| {
            let mut stmt = c.prepare_cached(&format!(
                "SELECT {THREAD_COLS} FROM threads
                 WHERE is_read = 0 AND is_inbox = 1 AND is_archived = 0
                   AND scheduled_at IS NULL AND needs_reply = 0
                   AND last_msg_at >= ?1
                   AND (suggestion_msg_count IS NULL OR suggestion_msg_count != msg_count)
                 ORDER BY last_msg_at DESC
                 LIMIT ?2"
            ))?;
            let rows = stmt.query_map(params![since, limit], row_to_thread)?;
            rows.collect()
        })
    }

    fn set_thread_suggestion(
        &self,
        thread_id: &ThreadId,
        suggestion: Option<&Suggestion>,
        at_msg_count: i64,
    ) -> Result<(), StoreError> {
        let json = suggestion
            .map(serde_json::to_string)
            .transpose()
            .map_err(err)?;
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET suggestion = ?2, suggestion_msg_count = ?3 WHERE id = ?1",
                params![thread_id, json, at_msg_count],
            )
        })?;
        if n == 0 {
            return Err(StoreError(format!("unknown thread {thread_id}")));
        }
        Ok(())
    }

    fn clear_thread_suggestion(&self, thread_id: &ThreadId) -> Result<bool, StoreError> {
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET suggestion = NULL WHERE id = ?1 AND suggestion IS NOT NULL",
                params![thread_id],
            )
        })?;
        Ok(n > 0)
    }

    fn set_thread_triage(
        &self,
        thread_id: &ThreadId,
        label_ids: &[String],
        priority: Priority,
        at_msg_count: i64,
    ) -> Result<(), StoreError> {
        let labels = serde_json::to_string(label_ids).map_err(err)?;
        // A manually-pinned thread keeps its user-chosen labels — only
        // priority/version move. The CASE runs inside SQLite so this stays
        // one statement instead of a read-modify-write race.
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET
                    triage_label_ids = CASE WHEN triage_labels_manual = 1 THEN triage_label_ids ELSE ?2 END,
                    priority = ?3,
                    triage_msg_count = ?4
                 WHERE id = ?1",
                params![thread_id, labels, priority.as_str(), at_msg_count],
            )
        })?;
        if n == 0 {
            return Err(StoreError(format!("unknown thread {thread_id}")));
        }
        Ok(())
    }

    /// User-driven label edit (footer "+" menu / badge ×): wholesale-replace
    /// and pin, so the next `set_thread_triage` leaves it alone.
    fn set_manual_triage_labels(
        &self,
        thread_id: &ThreadId,
        label_ids: &[String],
    ) -> Result<(), StoreError> {
        let labels = serde_json::to_string(label_ids).map_err(err)?;
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET triage_label_ids = ?2, triage_labels_manual = 1 WHERE id = ?1",
                params![thread_id, labels],
            )
        })?;
        if n == 0 {
            return Err(StoreError(format!("unknown thread {thread_id}")));
        }
        Ok(())
    }

    fn get_thread(&self, thread_id: &ThreadId) -> Result<Option<Thread>, StoreError> {
        self.read(|c| {
            c.query_row(
                &format!("SELECT {THREAD_COLS} FROM threads WHERE id = ?1"),
                params![thread_id],
                row_to_thread,
            )
            .optional()
        })
    }

    fn list_messages(&self, thread_id: &ThreadId) -> Result<Vec<Message>, StoreError> {
        self.read(|c| {
            let mut stmt = c.prepare_cached(&format!(
                "SELECT {MESSAGE_COLS} FROM messages WHERE thread_id = ?1 ORDER BY date"
            ))?;
            let rows = stmt.query_map(params![thread_id], row_to_message)?;
            rows.collect()
        })
    }

    fn list_message_meta(&self, thread_id: &ThreadId) -> Result<Vec<Message>, StoreError> {
        self.read(|c| {
            let mut stmt = c.prepare_cached(&format!(
                "SELECT {MESSAGE_META_COLS} FROM messages WHERE thread_id = ?1 ORDER BY date"
            ))?;
            let rows = stmt.query_map(params![thread_id], row_to_message)?;
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
        self.read(|c| {
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
                let mut stmt = c.prepare_cached(&format!(
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
                let mut stmt = c.prepare_cached(&format!(
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
            // Drafts land in the Drafts folder via the next delta sync too.
            Mutation::Send { .. } | Mutation::SaveDraft { .. } | Mutation::DeleteDraft { .. } => {
                return Ok(())
            }
            // Star is sugar over a STARRED label flip; both leave flags alone.
            Mutation::Star { thread_id, starred } => {
                return self.flip_label(thread_id, "STARRED", *starred);
            }
            Mutation::ModifyLabel {
                thread_id,
                label_id,
                add,
            } => {
                return self.flip_label(thread_id, label_id, *add);
            }
            Mutation::Archive { thread_id } => (thread_id, (true, false)),
            // Untrash and "not spam" land where Unarchive does: the inbox.
            Mutation::Unarchive { thread_id }
            | Mutation::Untrash { thread_id }
            | Mutation::MarkSpam {
                thread_id,
                spam: false,
            } => (thread_id, (false, true)),
            Mutation::Trash { thread_id }
            | Mutation::MarkSpam {
                thread_id,
                spam: true,
            } => (thread_id, (false, false)),
        };
        let Some(mut t) = self.get_thread(thread_id)? else {
            return Err(StoreError(format!("unknown thread {thread_id}")));
        };
        let (is_archived, is_inbox) = flags;
        // The folder label that goes with the move (none for Archive).
        let folder = match mutation {
            Mutation::Trash { .. } => Some("TRASH"),
            Mutation::MarkSpam { spam: true, .. } => Some("SPAM"),
            _ => None,
        };
        if is_inbox {
            t.labels.retain(|l| l != "TRASH" && l != "SPAM");
            if !t.labels.iter().any(|l| l == "INBOX") {
                t.labels.push("INBOX".to_string());
            }
        } else {
            t.labels.retain(|l| l != "INBOX");
            if let Some(folder) = folder {
                if !t.labels.iter().any(|l| l == folder) {
                    t.labels.push(folder.to_string());
                }
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

    fn outbox_push(&self, account_id: &AccountId, mutation: &Mutation) -> Result<i64, StoreError> {
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
            )?;
            Ok(c.last_insert_rowid())
        })
    }

    fn outbox_list(&self, limit: u32) -> Result<Vec<OutboxItem>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT id, account_id, mutation, attempts, created_at
                 FROM outbox ORDER BY id LIMIT ?1",
            )?;
            let rows = stmt.query_map(params![limit], row_to_outbox_item)?;
            rows.collect()
        })
    }

    fn outbox_list_due(
        &self,
        after_id: i64,
        limit: u32,
        max_attempts: i64,
    ) -> Result<Vec<OutboxItem>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT id, account_id, mutation, attempts, created_at
                 FROM outbox WHERE id > ?1 AND attempts < ?3 ORDER BY id LIMIT ?2",
            )?;
            let rows =
                stmt.query_map(params![after_id, limit, max_attempts], row_to_outbox_item)?;
            rows.collect()
        })
    }

    /// Counted without reading the rows: a queued send carries its
    /// attachments.
    fn outbox_counts(&self, max_attempts: i64) -> Result<(u32, u32), StoreError> {
        self.read(|c| {
            c.query_row(
                "SELECT COALESCE(SUM(attempts < ?1), 0), COALESCE(SUM(attempts >= ?1), 0)
                   FROM outbox",
                params![max_attempts],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
        })
    }

    fn outbox_contains(&self, id: i64) -> Result<bool, StoreError> {
        self.with(|c| {
            c.query_row(
                "SELECT 1 FROM outbox WHERE id = ?1",
                params![id],
                |_| Ok(()),
            )
            .optional()
            .map(|r| r.is_some())
        })
    }

    fn outbox_delete(&self, id: i64) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute("DELETE FROM outbox WHERE id = ?1", params![id])
                .map(|_| ())
        })
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

    /// Never synced to Gmail — `upsert_thread` leaves the column alone.
    fn set_schedule(
        &self,
        thread_id: &ThreadId,
        scheduled_at: Option<i64>,
    ) -> Result<bool, StoreError> {
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET scheduled_at = ?2 WHERE id = ?1",
                params![thread_id, scheduled_at],
            )
        })?;
        Ok(n > 0)
    }

    /// Never synced to Gmail — `upsert_thread` leaves the column alone.
    fn set_needs_reply(&self, thread_id: &ThreadId, needs_reply: bool) -> Result<bool, StoreError> {
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET needs_reply = ?2 WHERE id = ?1",
                params![thread_id, needs_reply],
            )
        })?;
        Ok(n > 0)
    }

    /// Never synced to Gmail — `upsert_thread` leaves the column alone.
    fn set_follow_up(
        &self,
        thread_id: &ThreadId,
        follow_up_since: Option<i64>,
    ) -> Result<bool, StoreError> {
        let n = self.with(|c| {
            c.execute(
                "UPDATE threads SET follow_up_since = ?2 WHERE id = ?1",
                params![thread_id, follow_up_since],
            )
        })?;
        Ok(n > 0)
    }

    fn sync_device_id(&self) -> Result<String, StoreError> {
        self.with(|c| {
            // 64 random bits from SQLite itself — no rand dependency here.
            c.execute(
                "INSERT OR IGNORE INTO sync_meta (account_id, key, value)
                 VALUES ('', 'device_id', lower(hex(randomblob(8))))",
                [],
            )?;
            c.query_row(
                "SELECT value FROM sync_meta WHERE account_id = '' AND key = 'device_id'",
                [],
                |r| r.get(0),
            )
        })
    }

    fn sync_entries(&self, account_id: &AccountId) -> Result<Vec<SyncEntry>, StoreError> {
        self.with(|c| {
            let mut stmt = c.prepare_cached(
                "SELECT key, value, ts, device FROM sync_kv WHERE account_id = ?1 ORDER BY key",
            )?;
            let rows = stmt.query_map(params![account_id], |r| {
                let raw: Option<String> = r.get(1)?;
                let value = match raw {
                    Some(s) => Some(serde_json::from_str(&s).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            1,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?),
                    None => None,
                };
                Ok(SyncEntry {
                    key: r.get(0)?,
                    value,
                    ts: r.get(2)?,
                    device: r.get(3)?,
                })
            })?;
            rows.collect()
        })
    }

    fn sync_merge(
        &self,
        account_id: &AccountId,
        entries: &[SyncEntry],
    ) -> Result<Vec<String>, StoreError> {
        let mut changed = Vec::new();
        self.with(|c| {
            let tx = c.unchecked_transaction()?;
            {
                // LWW in SQL: the conflict branch only fires when the
                // incoming (ts, device) is strictly greater — keep in
                // lockstep with SyncEntry::is_newer_than.
                let mut stmt = tx.prepare_cached(
                    "INSERT INTO sync_kv (account_id, key, value, ts, device)
                     VALUES (?1, ?2, ?3, ?4, ?5)
                     ON CONFLICT(account_id, key) DO UPDATE SET
                       value = excluded.value, ts = excluded.ts, device = excluded.device
                     WHERE excluded.ts > sync_kv.ts
                        OR (excluded.ts = sync_kv.ts AND excluded.device > sync_kv.device)",
                )?;
                for e in entries {
                    let value = e.value.as_ref().map(|v| v.to_string());
                    let n = stmt.execute(params![account_id, e.key, value, e.ts, e.device])?;
                    if n > 0 {
                        changed.push(e.key.clone());
                    }
                }
            }
            tx.commit()
        })?;
        Ok(changed)
    }

    fn sync_meta_get(
        &self,
        account_id: &AccountId,
        key: &str,
    ) -> Result<Option<String>, StoreError> {
        self.with(|c| {
            c.query_row(
                "SELECT value FROM sync_meta WHERE account_id = ?1 AND key = ?2",
                params![account_id, key],
                |r| r.get(0),
            )
            .optional()
        })
    }

    fn sync_meta_set(
        &self,
        account_id: &AccountId,
        key: &str,
        value: &str,
    ) -> Result<(), StoreError> {
        self.with(|c| {
            c.execute(
                "INSERT INTO sync_meta (account_id, key, value) VALUES (?1, ?2, ?3)
                 ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value",
                params![account_id, key, value],
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

    fn entry(key: &str, value: Option<i64>, ts: i64, device: &str) -> SyncEntry {
        SyncEntry {
            key: key.into(),
            value: value.map(Into::into),
            ts,
            device: device.into(),
        }
    }

    #[test]
    fn sync_device_id_is_created_once_and_stable() {
        let s = store();
        let id = s.sync_device_id().unwrap();
        assert_eq!(id.len(), 16, "8 random bytes, hex");
        assert_eq!(s.sync_device_id().unwrap(), id);
    }

    #[test]
    fn sync_merge_is_last_writer_wins() {
        let s = store();
        let acc = "a1".to_string();
        assert_eq!(
            s.sync_merge(&acc, &[entry("k", Some(1), 10, "a")]).unwrap(),
            vec!["k"]
        );
        // Older loses, equal ts + lower device loses, equal ts + higher device wins.
        assert!(s
            .sync_merge(&acc, &[entry("k", Some(2), 9, "z")])
            .unwrap()
            .is_empty());
        assert!(s
            .sync_merge(&acc, &[entry("k", Some(3), 10, "0")])
            .unwrap()
            .is_empty());
        assert_eq!(
            s.sync_merge(&acc, &[entry("k", Some(4), 10, "b")]).unwrap(),
            vec!["k"]
        );
        // Newer tombstone wins and reads back as None.
        assert_eq!(
            s.sync_merge(&acc, &[entry("k", None, 11, "a")]).unwrap(),
            vec!["k"]
        );
        let all = s.sync_entries(&acc).unwrap();
        assert_eq!(all, vec![entry("k", None, 11, "a")]);
        // Sorted by key; JSON values round-trip.
        s.sync_merge(
            &acc,
            &[entry("b", Some(2), 1, "a"), entry("a", Some(1), 1, "a")],
        )
        .unwrap();
        let keys: Vec<_> = s
            .sync_entries(&acc)
            .unwrap()
            .into_iter()
            .map(|e| e.key)
            .collect();
        assert_eq!(keys, vec!["a", "b", "k"]);
        assert_eq!(s.sync_entries(&acc).unwrap()[0].value, Some(1.into()));
        // Unknown account is rejected (FK), not silently accepted.
        assert!(s
            .sync_merge(&"nope".to_string(), &[entry("k", None, 1, "a")])
            .is_err());
    }

    #[test]
    fn sync_meta_round_trips_and_dies_with_account() {
        let s = store();
        let acc = "a1".to_string();
        assert_eq!(s.sync_meta_get(&acc, "file_id").unwrap(), None);
        s.sync_meta_set(&acc, "file_id", "f1").unwrap();
        s.sync_meta_set(&acc, "file_id", "f2").unwrap();
        assert_eq!(
            s.sync_meta_get(&acc, "file_id").unwrap().as_deref(),
            Some("f2")
        );
        s.sync_merge(&acc, &[entry("k", Some(1), 1, "a")]).unwrap();
        let device = s.sync_device_id().unwrap();
        s.delete_account("a1").unwrap();
        assert_eq!(s.sync_meta_get(&acc, "file_id").unwrap(), None);
        assert!(s.sync_entries(&acc).unwrap().is_empty());
        assert_eq!(
            s.sync_device_id().unwrap(),
            device,
            "device id is install-wide"
        );
    }

    #[tokio::test]
    async fn backfill_end_to_end_against_sqlite() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 25, 10);

        let n = sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        assert_eq!(n, 25);
        assert_eq!(
            store.list_accounts().unwrap()[0].history_id.as_deref(),
            Some("hist-1")
        );
        let threads = store
            .list_threads(None, &ThreadFilter::Inbox, None, 100)
            .unwrap();
        assert_eq!(threads.len(), 25);
        assert!(threads
            .windows(2)
            .all(|w| w[0].last_msg_at >= w[1].last_msg_at));

        // keyset pagination: second page strictly older, no overlap
        let page1 = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap();
        let page2 = store
            .list_threads(
                None,
                &ThreadFilter::Inbox,
                Some(page1.last().unwrap().last_msg_at),
                10,
            )
            .unwrap();
        assert_eq!(page2.len(), 10);
        assert!(page2[0].last_msg_at < page1.last().unwrap().last_msg_at);
    }

    #[tokio::test]
    async fn messages_round_trip() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        let t = &store
            .list_threads(None, &ThreadFilter::Inbox, None, 1)
            .unwrap()[0];
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
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let id = store
            .list_threads(None, &ThreadFilter::Inbox, None, 1)
            .unwrap()[0]
            .id
            .clone();

        outbox::enqueue(
            &store,
            &"a1".to_string(),
            Mutation::Archive {
                thread_id: id.clone(),
            },
        )
        .unwrap();

        // local view updated instantly; thread gone from inbox list
        assert!(store.get_thread(&id).unwrap().unwrap().is_archived);
        assert!(!store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()
            .iter()
            .any(|t| t.id == id));

        let (applied, failed) = outbox::drain(&provider, &store, 10).await.unwrap();
        assert_eq!((applied, failed), (1, 0));
        assert!(store.outbox_list(10).unwrap().is_empty());
    }

    #[tokio::test]
    async fn metadata_reupsert_preserves_fetched_bodies() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 1, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let t = store
            .list_threads(None, &ThreadFilter::Inbox, None, 1)
            .unwrap()[0]
            .clone();
        let mut m = store.list_messages(&t.id).unwrap()[0].clone();
        assert!(m.body_text.is_some(), "fixture has a body");

        // Metadata-tier refetch of the same message carries no bodies.
        m.body_html = None;
        m.body_text = None;
        store.upsert_message(&m).unwrap();

        let after = store.list_messages(&t.id).unwrap()[0].clone();
        assert!(
            after.body_text.is_some(),
            "body survives metadata re-upsert"
        );
    }

    #[tokio::test]
    async fn scheduled_at_survives_sync_reupsert() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let id = store
            .list_threads(None, &ThreadFilter::Inbox, None, 1)
            .unwrap()[0]
            .id
            .clone();

        store.set_schedule(&id, Some(1_756_700_000_000)).unwrap();
        assert_eq!(
            store.get_thread(&id).unwrap().unwrap().scheduled_at,
            Some(1_756_700_000_000)
        );

        // Delta/backfill re-upserts the same thread from provider data
        // (which never carries a schedule) — must not clobber it.
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        assert_eq!(
            store.get_thread(&id).unwrap().unwrap().scheduled_at,
            Some(1_756_700_000_000),
            "schedule survives provider re-upsert"
        );

        // Listing exposes it too (drives the calendar view).
        let listed = store.list_scheduled().unwrap();
        assert_eq!(
            listed.iter().find(|t| t.id == id).unwrap().scheduled_at,
            Some(1_756_700_000_000)
        );

        // Clearing works and unknown threads error.
        store.set_schedule(&id, None).unwrap();
        assert_eq!(store.get_thread(&id).unwrap().unwrap().scheduled_at, None);
        assert!(
            !store.set_schedule(&"nope".to_string(), Some(1)).unwrap(),
            "unknown thread → false"
        );
    }

    /// A reminder (due or not) or "needs reply" moves the thread out of
    /// the inbox list and badge into Scheduled / Need reply; clearing the
    /// flag brings it back. All mail keeps showing it throughout.
    #[test]
    fn reminder_or_needs_reply_moves_thread_out_of_inbox() {
        let s = store();
        seed_labelled(&s, "later", &["INBOX"], true, false, 8000);
        seed_labelled(&s, "due", &["INBOX"], true, false, 7000);
        seed_labelled(&s, "reply", &["INBOX"], true, false, 6000);
        seed_labelled(&s, "plain", &["INBOX"], true, false, 5000);
        s.with(|c| {
            c.execute("UPDATE threads SET is_read = 0", [])?;
            Ok(())
        })
        .unwrap();
        s.set_schedule(&"later".to_string(), Some(now_ms() + 86_400_000))
            .unwrap();
        s.set_schedule(&"due".to_string(), Some(now_ms() - 60_000))
            .unwrap();
        s.set_needs_reply(&"reply".to_string(), true).unwrap();

        assert_eq!(ids(&s, &ThreadFilter::Inbox), ["plain"]);
        assert_eq!(s.count_unread(None, &ThreadFilter::Inbox).unwrap(), 1);
        assert_eq!(
            ids(&s, &ThreadFilter::All),
            ["due", "later", "plain", "reply"]
        );
        assert_eq!(
            s.list_scheduled()
                .unwrap()
                .iter()
                .map(|t| t.id.as_str())
                .collect::<Vec<_>>(),
            ["due", "later"]
        );

        s.set_schedule(&"later".to_string(), None).unwrap();
        s.set_needs_reply(&"reply".to_string(), false).unwrap();
        assert_eq!(ids(&s, &ThreadFilter::Inbox), ["later", "plain", "reply"]);
        assert_eq!(s.count_unread(None, &ThreadFilter::Inbox).unwrap(), 3);
    }

    #[tokio::test]
    async fn done_drops_thread_from_scheduled_and_need_reply() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let ids: Vec<_> = store
            .list_threads(None, &ThreadFilter::Inbox, None, 2)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
        let (done, elsewhere) = (&ids[0], &ids[1]);
        for id in [done, elsewhere] {
            store.set_schedule(id, Some(42)).unwrap();
            store.set_needs_reply(id, true).unwrap();
        }

        // Done in the app clears the flags.
        outbox::enqueue(
            &store,
            &"a1".to_string(),
            Mutation::Archive {
                thread_id: done.clone(),
            },
        )
        .unwrap();
        let t = store.get_thread(done).unwrap().unwrap();
        assert_eq!((t.scheduled_at, t.needs_reply), (None, false));

        // Archived elsewhere (Gmail): the flags remain, but the lists only
        // hold mail still in the inbox.
        store
            .with(|c| {
                c.execute(
                    "UPDATE threads SET is_inbox = 0, is_archived = 1 WHERE id = ?1",
                    params![elsewhere],
                )
            })
            .unwrap();
        assert!(store.list_scheduled().unwrap().is_empty());
        assert!(store.list_needs_reply().unwrap().is_empty());
    }

    #[tokio::test]
    async fn follow_up_since_persists_and_survives_sync_reupsert() {
        let store = SqliteStore::open_in_memory().unwrap();
        store.upsert_account(&sample_account("a1")).unwrap();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let id = store
            .list_threads(None, &ThreadFilter::Inbox, None, 1)
            .unwrap()[0]
            .id
            .clone();
        let t = store.get_thread(&id).unwrap().unwrap();
        assert_eq!(t.follow_up_since, None);
        // Armed after the thread's newest message — otherwise the backfill's
        // own follow-up settling (core) would rightly treat that message as
        // the awaited reply.
        let since = t.last_msg_at + 1;
        assert!(store.set_follow_up(&id, Some(since)).unwrap());
        assert_eq!(
            store.get_thread(&id).unwrap().unwrap().follow_up_since,
            Some(since)
        );
        // Provider re-upsert must not clobber it (local-only column).
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        assert_eq!(
            store.get_thread(&id).unwrap().unwrap().follow_up_since,
            Some(since)
        );
        assert!(store.set_follow_up(&id, None).unwrap());
        assert_eq!(
            store.get_thread(&id).unwrap().unwrap().follow_up_since,
            None
        );
        assert!(!store.set_follow_up(&"nope".to_string(), Some(1)).unwrap());
    }

    #[tokio::test]
    async fn needs_reply_survives_sync_reupsert_and_feeds_its_view() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let id = store
            .list_threads(None, &ThreadFilter::Inbox, None, 1)
            .unwrap()[0]
            .id
            .clone();
        assert!(!store.get_thread(&id).unwrap().unwrap().needs_reply);

        assert!(store.set_needs_reply(&id, true).unwrap());
        assert!(store.get_thread(&id).unwrap().unwrap().needs_reply);

        // Provider data never carries the flag — a re-upsert must keep it.
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        assert!(
            store.get_thread(&id).unwrap().unwrap().needs_reply,
            "needs_reply survives provider re-upsert"
        );
        // It moves from the inbox to the Need reply feed.
        assert!(!store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()
            .iter()
            .any(|t| t.id == id));
        let flagged = store.list_needs_reply().unwrap();
        assert_eq!(flagged.iter().filter(|t| t.id == id).count(), 1);
        assert!(flagged.iter().all(|t| t.needs_reply));

        // Clearing removes it; unknown threads report false.
        assert!(store.set_needs_reply(&id, false).unwrap());
        assert!(!store.list_needs_reply().unwrap().iter().any(|t| t.id == id));
        assert!(!store.set_needs_reply(&"nope".to_string(), true).unwrap());
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
            needs_reply: false,
            follow_up_since: None,
            suggestion: None,
            bundle_id: None,
            labels: labels.iter().map(|s| s.to_string()).collect(),
            has_attachment: false,
            priority: None,
            triage_label_ids: Vec::new(),
        })
        .unwrap();
    }

    fn ids(s: &SqliteStore, f: &ThreadFilter) -> Vec<String> {
        let mut v: Vec<String> = s
            .list_threads(None, f, None, 100)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
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
        seed_labelled(
            &s,
            "trash-star",
            &["STARRED", "TRASH", "Label_9"],
            false,
            false,
            1000,
        );
        // partially-trashed thread (one message trashed elsewhere) keeps
        // INBOX — still lives in Inbox AND All, plus Trash
        seed_labelled(&s, "part-trash", &["INBOX", "TRASH"], true, false, 900);
        // a trashed draft belongs to Trash only, not Drafts
        seed_labelled(&s, "trash-draft", &["DRAFT", "TRASH"], false, false, 800);

        assert_eq!(ids(&s, &ThreadFilter::Inbox), ["in", "part-trash", "star"]);
        assert_eq!(ids(&s, &ThreadFilter::Starred), ["star"]);
        assert_eq!(ids(&s, &ThreadFilter::Sent), ["sent"]);
        assert_eq!(
            ids(&s, &ThreadFilter::Drafts),
            ["draft"],
            "trashed draft hidden from Drafts"
        );
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
            needs_reply: false,
            follow_up_since: None,
            suggestion: None,
            bundle_id: None,
            labels: labels.iter().map(|s| s.to_string()).collect(),
            has_attachment: false,
            priority: None,
            triage_label_ids: Vec::new(),
        };
        s.upsert_thread(&mk("a-unread", "a1", &["INBOX"], true, false))
            .unwrap();
        s.upsert_thread(&mk("a-read", "a1", &["INBOX"], true, true))
            .unwrap();
        s.upsert_thread(&mk("b-unread", "a2", &["INBOX"], true, false))
            .unwrap();
        // not in the inbox — must not count toward Inbox, only its own label
        s.upsert_thread(&mk("a-label-unread", "a1", &["Label_1"], false, false))
            .unwrap();

        assert_eq!(
            s.count_unread(None, &ThreadFilter::Inbox).unwrap(),
            2,
            "both accounts"
        );
        assert_eq!(
            s.count_unread(Some(&"a1".to_string()), &ThreadFilter::Inbox)
                .unwrap(),
            1,
            "account-scoped"
        );
        assert_eq!(
            s.count_unread(
                Some(&"a1".to_string()),
                &ThreadFilter::Label("Label_1".to_string())
            )
            .unwrap(),
            1
        );
        assert_eq!(
            s.count_unread(
                Some(&"a1".to_string()),
                &ThreadFilter::Label("Label_2".to_string())
            )
            .unwrap(),
            0,
            "non-matching label"
        );
    }

    #[test]
    fn trash_apply_local_moves_thread_into_trash_folder() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 1000);
        s.apply_local(&Mutation::Trash {
            thread_id: "t1".to_string(),
        })
        .unwrap();
        assert_eq!(ids(&s, &ThreadFilter::Inbox), Vec::<String>::new());
        assert_eq!(ids(&s, &ThreadFilter::Trash), ["t1"]);
        // archive: INBOX label drops so the thread leaves the label-derived views
        seed_labelled(&s, "t2", &["INBOX", "STARRED"], true, false, 1000);
        s.apply_local(&Mutation::Archive {
            thread_id: "t2".to_string(),
        })
        .unwrap();
        let t2 = s.get_thread(&"t2".to_string()).unwrap().unwrap();
        assert!(t2.is_archived && !t2.is_inbox);
        assert_eq!(t2.labels, vec!["STARRED".to_string()]);
    }

    #[test]
    fn unarchive_apply_local_restores_thread_to_inbox() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX", "STARRED"], true, false, 1000);
        s.apply_local(&Mutation::Archive {
            thread_id: "t1".to_string(),
        })
        .unwrap();
        assert_eq!(ids(&s, &ThreadFilter::Inbox), Vec::<String>::new());

        s.apply_local(&Mutation::Unarchive {
            thread_id: "t1".to_string(),
        })
        .unwrap();
        let t1 = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert!(t1.is_inbox && !t1.is_archived);
        assert_eq!(t1.labels, vec!["STARRED".to_string(), "INBOX".to_string()]);
        assert_eq!(ids(&s, &ThreadFilter::Inbox), ["t1"]);

        // idempotent: unarchiving an already-inbox thread doesn't duplicate INBOX
        s.apply_local(&Mutation::Unarchive {
            thread_id: "t1".to_string(),
        })
        .unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string()).unwrap().unwrap().labels,
            vec!["STARRED".to_string(), "INBOX".to_string()]
        );
    }

    #[test]
    fn star_and_modify_label_apply_local_flip_labels_only() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 1000);
        let star = |on: bool| Mutation::Star {
            thread_id: "t1".to_string(),
            starred: on,
        };
        s.apply_local(&star(true)).unwrap();
        let t = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t.labels, ["INBOX", "STARRED"]);
        assert!(
            t.is_inbox && !t.is_archived,
            "star must not move the thread"
        );
        assert_eq!(ids(&s, &ThreadFilter::Starred), ["t1"]);
        // idempotent: starring again doesn't duplicate the label
        s.apply_local(&star(true)).unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string()).unwrap().unwrap().labels,
            ["INBOX", "STARRED"]
        );
        s.apply_local(&star(false)).unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string()).unwrap().unwrap().labels,
            ["INBOX"]
        );
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
        let missing = Mutation::Star {
            thread_id: "nope".to_string(),
            starred: true,
        };
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
        s.set_labels(&"a1".to_string(), &[l("L1", "zeta"), l("L2", "Alpha")])
            .unwrap();
        let listed = s.list_labels().unwrap();
        assert_eq!(
            listed.iter().map(|x| x.name.as_str()).collect::<Vec<_>>(),
            ["Alpha", "zeta"],
            "name-sorted, case-insensitive"
        );
        // wholesale replace: deleted labels disappear
        s.set_labels(&"a1".to_string(), &[l("L2", "Alpha renamed")])
            .unwrap();
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
        s.set_labels(&"a1".to_string(), &[l("L1", "Old"), l("L2", "Keep")])
            .unwrap();
        seed_labelled(&s, "t1", &["INBOX", "L1"], true, false, 2000);
        seed_labelled(&s, "t2", &["L1", "L2"], false, true, 1000);

        s.rename_label("a1", "L1", "New").unwrap();
        let names: Vec<String> = s
            .list_labels()
            .unwrap()
            .into_iter()
            .map(|x| x.name)
            .collect();
        assert_eq!(names, ["Keep", "New"]);

        s.delete_label("a1", "L1").unwrap();
        let listed = s.list_labels().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, "L2");
        // threads no longer carry the deleted id…
        assert_eq!(
            s.get_thread(&"t1".to_string()).unwrap().unwrap().labels,
            ["INBOX"]
        );
        assert_eq!(
            s.get_thread(&"t2".to_string()).unwrap().unwrap().labels,
            ["L2"]
        );
        // …so the label view is empty while other labels keep working.
        assert_eq!(
            ids(&s, &ThreadFilter::Label("L1".to_string())),
            Vec::<String>::new()
        );
        assert_eq!(ids(&s, &ThreadFilter::Label("L2".to_string())), ["t2"]);
    }

    #[test]
    fn bundles_membership_anchors_and_exclusions() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 1000);
        seed_labelled(&s, "t2", &["INBOX"], true, false, 900);
        seed_labelled(&s, "junk", &["TRASH"], true, false, 800);

        let mut b = Bundle {
            id: "b1".into(),
            name: "Lisbon trip".into(),
            kind: BundleKind::Trip,
            description: String::new(),
            status: BundleStatus::Active,
            origin: BundleOrigin::User,
            created_at: 1,
            updated_at: 1,
        };
        s.upsert_bundle(&b).unwrap();
        b.name = "Lisbon".into();
        b.status = BundleStatus::Archived;
        b.origin = BundleOrigin::Ai;
        b.updated_at = 2;
        s.upsert_bundle(&b).unwrap();
        assert_eq!(s.list_bundles().unwrap(), vec![b.clone()]);

        let t1 = "t1".to_string();
        assert!(s
            .set_thread_bundle(&t1, Some(("b1", BundleSource::User)))
            .unwrap());
        s.set_thread_bundle(&"junk".to_string(), Some(("b1", BundleSource::Link)))
            .unwrap();
        assert!(!s
            .set_thread_bundle(&"nope".to_string(), Some(("b1", BundleSource::User)))
            .unwrap());
        assert_eq!(
            s.thread_bundle_source(&t1).unwrap(),
            Some(BundleSource::User)
        );
        assert_eq!(
            s.get_thread(&t1).unwrap().unwrap().bundle_id.as_deref(),
            Some("b1")
        );
        // Trash never shows in a bundle.
        let ids: Vec<String> = s
            .list_bundle_threads("b1")
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
        assert_eq!(ids, vec!["t1"]);
        // A provider re-upsert keeps the membership (local-only column).
        seed_labelled(&s, "t1", &["INBOX"], false, false, 1100);
        assert_eq!(
            s.get_thread(&t1).unwrap().unwrap().bundle_id.as_deref(),
            Some("b1")
        );

        assert_eq!(s.list_threads_needing_anchors(10).unwrap().len(), 3);
        s.set_thread_anchors(&t1, &["order:1".into(), "booking:K7".into()], 1)
            .unwrap();
        s.set_thread_anchors(&"t2".to_string(), &["order:1".into()], 1)
            .unwrap();
        assert_eq!(s.list_threads_needing_anchors(10).unwrap().len(), 1);
        assert_eq!(
            s.thread_anchors(&t1).unwrap(),
            vec!["booking:K7", "order:1"]
        );
        assert_eq!(
            s.threads_with_anchors(&["order:1".into()]).unwrap(),
            vec![
                ("t1".to_string(), vec!["order:1".to_string()]),
                ("t2".to_string(), vec!["order:1".to_string()])
            ]
        );

        s.exclude_from_bundle("b1", &"t2".to_string()).unwrap();
        assert!(s.is_excluded_from_bundle("b1", &"t2".to_string()).unwrap());
        assert_eq!(
            s.list_bundle_exclusions("b1").unwrap(),
            vec!["t2".to_string()]
        );
        s.clear_bundle_exclusion("b1", &"t2".to_string()).unwrap();
        assert!(!s.is_excluded_from_bundle("b1", &"t2".to_string()).unwrap());

        s.delete_bundle("b1").unwrap();
        assert!(s.list_bundles().unwrap().is_empty());
        assert!(s.get_thread(&t1).unwrap().unwrap().bundle_id.is_none());
        assert_eq!(s.thread_bundle_source(&t1).unwrap(), None);
    }

    #[test]
    fn triage_label_create_rename_delete_and_needs_triage() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 1000);
        seed_labelled(&s, "t2", &["INBOX"], true, false, 900);

        // Never classified — both threads need it.
        assert_eq!(s.list_threads_needing_triage(10).unwrap().len(), 2);
        // The count agrees, and the window leaves out older mail.
        assert_eq!(s.count_threads_needing_triage(0).unwrap(), 2);
        assert_eq!(s.count_threads_needing_triage(950).unwrap(), 1);

        let label = s.create_triage_label("Bills").unwrap();
        s.set_thread_triage(
            &"t1".to_string(),
            std::slice::from_ref(&label.id),
            Priority::High,
            1,
        )
        .unwrap();

        // t1 is current now (triage_msg_count matches msg_count); t2 isn't.
        let pending: Vec<String> = s
            .list_threads_needing_triage(10)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
        assert_eq!(pending, ["t2"]);
        assert_eq!(s.count_threads_needing_triage(0).unwrap(), 1);
        let t1 = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t1.priority, Some(Priority::High));
        assert_eq!(t1.triage_label_ids, vec![label.id.clone()]);

        // A new label may match mail already synced — invalidates everyone,
        // including t1, so the poller gets a chance to backfill old mail.
        s.create_triage_label("Work").unwrap();
        assert_eq!(
            s.list_threads_needing_triage(10).unwrap().len(),
            2,
            "new label makes every thread stale again"
        );
        s.set_thread_triage(
            &"t1".to_string(),
            std::slice::from_ref(&label.id),
            Priority::High,
            1,
        )
        .unwrap();

        s.rename_triage_label(&label.id, "Bills & Receipts")
            .unwrap();
        assert_eq!(
            s.list_triage_labels()
                .unwrap()
                .iter()
                .find(|l| l.id == label.id)
                .unwrap()
                .name,
            "Bills & Receipts"
        );

        s.delete_triage_label(&label.id).unwrap();
        assert!(s
            .list_triage_labels()
            .unwrap()
            .iter()
            .all(|l| l.id != label.id));
        assert!(
            s.get_thread(&"t1".to_string())
                .unwrap()
                .unwrap()
                .triage_label_ids
                .is_empty(),
            "deleted label stripped from threads"
        );
    }

    #[test]
    fn create_triage_label_rejects_duplicate_name_case_insensitively() {
        let s = store();
        s.create_triage_label("Bills").unwrap();
        assert!(s.create_triage_label("bills").is_err());
    }

    #[test]
    fn triage_label_ids_are_random_hex_not_a_counter() {
        let s = store();
        let a = s.create_triage_label("Bills").unwrap();
        let b = s.create_triage_label("Work").unwrap();
        assert_ne!(a.id, b.id);
        for id in [&a.id, &b.id] {
            assert_eq!(id.len(), 32, "{id}");
            assert!(id.chars().all(|c| c.is_ascii_hexdigit()), "{id}");
        }
        // A second store never mints the same id (the whole point).
        let other = store();
        assert_ne!(other.create_triage_label("Bills").unwrap().id, a.id);
    }

    #[test]
    fn upsert_triage_label_inserts_by_remote_id_then_renames() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 1000);
        s.set_thread_triage(&"t1".to_string(), &[], Priority::Low, 1)
            .unwrap();
        assert!(s.list_threads_needing_triage(10).unwrap().is_empty());
        let remote = TriageLabel {
            id: "remote-id".to_string(),
            name: "Bills".to_string(),
        };
        s.upsert_triage_label(&remote).unwrap();
        assert_eq!(s.list_triage_labels().unwrap(), vec![remote.clone()]);
        assert_eq!(
            s.list_threads_needing_triage(10).unwrap().len(),
            1,
            "a new label makes existing mail stale"
        );
        s.set_thread_triage(&"t1".to_string(), &[], Priority::Low, 1)
            .unwrap();
        s.upsert_triage_label(&TriageLabel {
            id: "remote-id".to_string(),
            name: "Receipts".to_string(),
        })
        .unwrap();
        assert_eq!(s.list_triage_labels().unwrap()[0].name, "Receipts");
        assert!(
            s.list_threads_needing_triage(10).unwrap().is_empty(),
            "a rename does not invalidate"
        );
        // Same name under a second id (created on another device before
        // the first sync) is allowed to coexist.
        s.upsert_triage_label(&TriageLabel {
            id: "other-id".to_string(),
            name: "receipts".to_string(),
        })
        .unwrap();
        assert_eq!(s.list_triage_labels().unwrap().len(), 2);
    }

    #[test]
    fn clear_manual_triage_labels_lifts_pin_and_marks_stale() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 1000);
        let bills = s.create_triage_label("Bills").unwrap();
        let work = s.create_triage_label("Work").unwrap();
        s.set_manual_triage_labels(&"t1".to_string(), std::slice::from_ref(&work.id))
            .unwrap();
        s.set_thread_triage(
            &"t1".to_string(),
            std::slice::from_ref(&bills.id),
            Priority::Low,
            1,
        )
        .unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string())
                .unwrap()
                .unwrap()
                .triage_label_ids,
            vec![work.id.clone()]
        );
        assert!(s.clear_manual_triage_labels(&"t1".to_string()).unwrap());
        assert!(!s.clear_manual_triage_labels(&"nope".to_string()).unwrap());
        assert_eq!(
            s.list_threads_needing_triage(10).unwrap().len(),
            1,
            "stale again so Jev takes a fresh pass"
        );
        s.set_thread_triage(
            &"t1".to_string(),
            std::slice::from_ref(&bills.id),
            Priority::Low,
            1,
        )
        .unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string())
                .unwrap()
                .unwrap()
                .triage_label_ids,
            vec![bills.id]
        );
    }

    #[test]
    fn prefs_round_trip_as_json() {
        let s = store();
        assert_eq!(s.get_pref("pin_list").unwrap(), None);
        assert!(s.list_prefs().unwrap().is_empty());
        s.set_pref("pin_list", Some(&serde_json::json!(true)))
            .unwrap();
        s.set_pref("hover_actions", Some(&serde_json::json!(["pin", "remind"])))
            .unwrap();
        s.set_pref("pin_list", Some(&serde_json::json!(false)))
            .unwrap();
        assert_eq!(
            s.get_pref("pin_list").unwrap(),
            Some(serde_json::json!(false))
        );
        assert_eq!(
            s.list_prefs().unwrap(),
            vec![
                (
                    "hover_actions".to_string(),
                    serde_json::json!(["pin", "remind"])
                ),
                ("pin_list".to_string(), serde_json::json!(false)),
            ]
        );
        s.set_pref("pin_list", None).unwrap();
        assert_eq!(s.get_pref("pin_list").unwrap(), None);
        assert_eq!(s.list_prefs().unwrap().len(), 1);
    }

    #[test]
    fn v15_migration_remaps_counter_label_ids_on_rows_and_threads() {
        let dir = std::env::temp_dir().join(format!("heypigeon-test-v15-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v14.db");
        let _ = std::fs::remove_file(&path);
        {
            let conn = Connection::open(&path).unwrap();
            let _ = SqliteStore::init_to(conn, 14).unwrap(); // pre-v15 schema
        }
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute(
                "INSERT INTO accounts (id, email, display_name, color, history_id)
                 VALUES ('a1', 'a1@example.com', 'A1', 'sky', 'hist-1')",
                [],
            )
            .unwrap();
            conn.execute_batch(
                "INSERT INTO triage_labels (id, name) VALUES (1, 'Bills'), (2, 'Work');
                 INSERT INTO threads (id, account_id, subject, snippet, last_msg_at, is_read,
                                      is_inbox, is_archived, msg_count, from_summary, last_from_addr,
                                      labels, has_attachment, triage_label_ids, triage_labels_manual)
                 VALUES ('t1', 'a1', 'Old row', 'snip', 1000, 1, 1, 0, 1, 'Someone',
                         'someone@x.com', '[]', 0, '[\"2\",\"1\"]', 1),
                        ('t2', 'a1', 'Other', 'snip', 900, 1, 1, 0, 1, 'Someone',
                         'someone@x.com', '[]', 0, '[]', 0);",
            )
            .unwrap();
        }
        let s = SqliteStore::open(&path).unwrap(); // runs v15
        let labels = s.list_triage_labels().unwrap();
        let by_name = |n: &str| labels.iter().find(|l| l.name == n).unwrap().id.clone();
        assert_eq!(labels.len(), 2);
        assert!(labels.iter().all(|l| l.id.len() == 32), "{labels:?}");
        let t1 = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t1.triage_label_ids, vec![by_name("Work"), by_name("Bills")]);
        assert!(s
            .get_thread(&"t2".to_string())
            .unwrap()
            .unwrap()
            .triage_label_ids
            .is_empty());
        // The manual pin survived the rewrite.
        s.set_thread_triage(&"t1".to_string(), &[], Priority::Low, 1)
            .unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string())
                .unwrap()
                .unwrap()
                .triage_label_ids
                .len(),
            2
        );
        // New labels after the upgrade get the same shape of id and can be
        // deleted by it (strip-from-threads still works on TEXT ids).
        let new = s.create_triage_label("New").unwrap();
        assert_eq!(new.id.len(), 32);
        s.delete_triage_label(&by_name("Work")).unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string())
                .unwrap()
                .unwrap()
                .triage_label_ids,
            vec![by_name("Bills")]
        );
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn triage_survives_sync_reupsert() {
        let s = store();
        let provider = FakeProvider::with_sample_data("a1", 1, 10);
        sync::backfill(&provider, &s, &"a1".to_string(), 30)
            .await
            .unwrap();
        let id = s.list_threads(None, &ThreadFilter::Inbox, None, 1).unwrap()[0]
            .id
            .clone();
        let label = s.create_triage_label("Newsletter").unwrap();
        let t = s.get_thread(&id).unwrap().unwrap();
        s.set_thread_triage(
            &id,
            std::slice::from_ref(&label.id),
            Priority::Low,
            t.msg_count,
        )
        .unwrap();

        // Provider data never carries triage — a re-upsert must not clobber it.
        sync::backfill(&provider, &s, &"a1".to_string(), 30)
            .await
            .unwrap();

        let after = s.get_thread(&id).unwrap().unwrap();
        assert_eq!(after.priority, Some(Priority::Low));
        assert_eq!(after.triage_label_ids, vec![label.id]);
    }

    #[test]
    fn suggestion_queue_versions_and_survives_reupsert() {
        let s = store();
        let unread = |id: &str, at: i64| {
            seed_labelled(&s, id, &["INBOX"], true, false, at);
            let mut t = s.get_thread(&id.to_string()).unwrap().unwrap();
            t.is_read = false;
            s.upsert_thread(&t).unwrap();
        };
        unread("new", 5_000);
        unread("older", 4_000);
        unread("too-old", 500);
        seed_labelled(&s, "read", &["INBOX"], true, false, 5_000);
        unread("flagged", 5_000);
        s.set_needs_reply(&"flagged".to_string(), true).unwrap();
        unread("snoozed", 5_000);
        s.set_schedule(&"snoozed".to_string(), Some(9_000)).unwrap();

        let ids = |since| -> Vec<String> {
            s.list_threads_needing_suggestion(since, 10)
                .unwrap()
                .into_iter()
                .map(|t| t.id)
                .collect()
        };
        assert_eq!(ids(1_000), vec!["new", "older"]);

        let remind = Suggestion::Remind { at: 99_000 };
        s.set_thread_suggestion(&"new".to_string(), Some(&remind), 1)
            .unwrap();
        s.set_thread_suggestion(&"older".to_string(), None, 1)
            .unwrap();
        assert!(ids(1_000).is_empty());

        // Provider data never carries the suggestion.
        let mut t = s.get_thread(&"new".to_string()).unwrap().unwrap();
        t.subject = "Renamed".into();
        s.upsert_thread(&t).unwrap();
        assert_eq!(
            s.get_thread(&"new".to_string())
                .unwrap()
                .unwrap()
                .suggestion,
            Some(remind)
        );

        // Dismissed: gone, and not due again for the same message…
        assert!(s.clear_thread_suggestion(&"new".to_string()).unwrap());
        assert!(!s.clear_thread_suggestion(&"new".to_string()).unwrap());
        assert_eq!(
            s.get_thread(&"new".to_string())
                .unwrap()
                .unwrap()
                .suggestion,
            None
        );
        assert!(ids(1_000).is_empty());
        // …but a new message makes it due again.
        t.msg_count = 2;
        s.upsert_thread(&t).unwrap();
        assert_eq!(ids(1_000), vec!["new"]);
    }

    #[test]
    fn manual_triage_labels_survive_reclassification_until_reset() {
        let s = store();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 1000);
        let bills = s.create_triage_label("Bills").unwrap();
        let work = s.create_triage_label("Work").unwrap();

        // User manually picks "Work" for this thread.
        s.set_manual_triage_labels(&"t1".to_string(), std::slice::from_ref(&work.id))
            .unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string())
                .unwrap()
                .unwrap()
                .triage_label_ids,
            vec![work.id.clone()]
        );

        // Jev reclassifies (e.g. a new message bumped msg_count) and would
        // have said "Bills" — the manual pin must win; priority still moves.
        s.set_thread_triage(
            &"t1".to_string(),
            std::slice::from_ref(&bills.id),
            Priority::High,
            1,
        )
        .unwrap();
        let t1 = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(
            t1.triage_label_ids,
            vec![work.id.clone()],
            "manual pin wins over Jev"
        );
        assert_eq!(t1.priority, Some(Priority::High), "priority still updates");

        // "Reanalyze all emails" clears the pin — Jev's next pass applies.
        s.reset_triage().unwrap();
        s.set_thread_triage(
            &"t1".to_string(),
            std::slice::from_ref(&bills.id),
            Priority::Medium,
            1,
        )
        .unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string())
                .unwrap()
                .unwrap()
                .triage_label_ids,
            vec![bills.id],
            "reset_triage lifts the pin"
        );
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
        assert!(
            t.labels.is_empty(),
            "pre-v7 rows default to '[]', healed by backfill"
        );
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

    #[test]
    fn v16_migration_clears_checkpoint_so_sender_rows_are_rebuilt() {
        let dir = std::env::temp_dir().join(format!("heypigeon-test-v16-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v15.db");
        let _ = std::fs::remove_file(&path);
        {
            let conn = Connection::open(&path).unwrap();
            let _ = SqliteStore::init_to(conn, 15).unwrap(); // pre-v16 schema
            let conn = Connection::open(&path).unwrap();
            conn.execute(
                "INSERT INTO accounts (id, email, display_name, color, history_id)
                 VALUES ('a1', 'a1@example.com', 'A1', 'sky', 'hist-42')",
                [],
            )
            .unwrap();
        }
        let s = SqliteStore::open(&path).unwrap();
        assert!(
            s.list_accounts().unwrap()[0].history_id.is_none(),
            "v16 forces a one-time backfill so every row re-derives its sender"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// v17 rewrites the cached sender of every thread from its stored
    /// messages — including threads far older than the sync window, which
    /// the v16 backfill never touches.
    #[test]
    fn v17_migration_rederives_list_sender_from_cached_messages() {
        let dir = std::env::temp_dir().join(format!("heypigeon-test-v17-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v16.db");
        let _ = std::fs::remove_file(&path);
        {
            let conn = Connection::open(&path).unwrap();
            let _ = SqliteStore::init_to(conn, 16).unwrap(); // pre-v17 schema
            let conn = Connection::open(&path).unwrap();
            conn.execute(
                "INSERT INTO accounts (id, email, display_name, color)
                 VALUES ('me@example.com', 'me@example.com', 'Me', 'sky')",
                [],
            )
            .unwrap();
            // Two threads the user replied to, cached under the old rule
            // (newest sender = the user), plus one with no cached messages.
            for (id, summary) in [("t1", "Me"), ("t2", "Me"), ("t3", "Someone")] {
                conn.execute(
                    "INSERT INTO threads (id, account_id, subject, snippet, last_msg_at, is_read,
                                          is_inbox, is_archived, msg_count, from_summary, last_from_addr)
                     VALUES (?1, 'me@example.com', 'S', '', 1000, 1, 1, 0, 2, ?2, 'me@example.com')",
                    params![id, summary],
                )
                .unwrap();
            }
            let mut insert = conn
                .prepare(
                    "INSERT INTO messages (id, thread_id, account_id, from_addr, to_addrs, date,
                                           snippet, label_ids, is_read)
                     VALUES (?1, ?2, 'me@example.com', ?3, ?4, ?5, '', ?6, 1)",
                )
                .unwrap();
            insert
                .execute(params![
                    "t1-m1",
                    "t1",
                    "Priya Nair <priya@acme.co>",
                    "[\"me@example.com\"]",
                    1,
                    "[\"INBOX\"]"
                ])
                .unwrap();
            insert
                .execute(params![
                    "t1-m2",
                    "t1",
                    "Me <me@example.com>",
                    "[\"priya@acme.co\"]",
                    2,
                    "[\"SENT\"]"
                ])
                .unwrap();
            // t2: the reply came from a send-as alias and is still a draft.
            insert
                .execute(params![
                    "t2-m1",
                    "t2",
                    "Sam Lee <sam@acme.co>",
                    "[\"me@example.com\"]",
                    1,
                    "[\"INBOX\"]"
                ])
                .unwrap();
            insert
                .execute(params![
                    "t2-m2",
                    "t2",
                    "Alias <alias@example.com>",
                    "[\"sam@acme.co\"]",
                    2,
                    "[\"DRAFT\"]"
                ])
                .unwrap();
        }
        let s = SqliteStore::open(&path).unwrap();
        let t1 = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t1.from_summary, "Priya Nair");
        assert_eq!(t1.last_from_addr, "priya@acme.co");
        let t2 = s.get_thread(&"t2".to_string()).unwrap().unwrap();
        assert_eq!(t2.from_summary, "Sam Lee");
        assert_eq!(t2.last_from_addr, "sam@acme.co");
        let t3 = s.get_thread(&"t3".to_string()).unwrap().unwrap();
        assert_eq!(
            t3.from_summary, "Someone",
            "no cached messages: left for the next provider upsert"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn v11_migration_adds_triage_columns_to_existing_data() {
        let dir = std::env::temp_dir().join(format!("heypigeon-test-v11-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v10.db");
        let _ = std::fs::remove_file(&path);
        {
            let conn = Connection::open(&path).unwrap();
            let _ = SqliteStore::init_to(conn, 10).unwrap(); // pre-v11 schema
        }
        {
            // Raw v10-shape rows — upsert_thread would already write `labels`
            // and `has_attachment`, which exist by v10; triage columns don't.
            let conn = Connection::open(&path).unwrap();
            conn.execute(
                "INSERT INTO accounts (id, email, display_name, color, history_id)
                 VALUES ('a1', 'a1@example.com', 'A1', 'sky', 'hist-1')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO threads (id, account_id, subject, snippet, last_msg_at, is_read,
                                      is_inbox, is_archived, msg_count, from_summary, last_from_addr,
                                      labels, has_attachment)
                 VALUES ('t1', 'a1', 'Old row', 'snip', 1000, 1, 1, 0, 1, 'Someone',
                         'someone@x.com', '[]', 0)",
                [],
            )
            .unwrap();
        }
        let s = SqliteStore::open(&path).unwrap(); // runs v11
        let t = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t.priority, None, "pre-existing rows default to no priority");
        assert!(
            t.triage_label_ids.is_empty(),
            "pre-existing rows default to '[]'"
        );
        assert!(s.list_triage_labels().unwrap().is_empty());
        // New capability works immediately after upgrade, on the pre-existing row.
        let label = s.create_triage_label("Bills").unwrap();
        s.set_thread_triage(
            &"t1".to_string(),
            std::slice::from_ref(&label.id),
            Priority::High,
            1,
        )
        .unwrap();
        let after = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(after.priority, Some(Priority::High));
        assert_eq!(after.triage_label_ids, vec![label.id]);
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn delete_account_removes_labels_and_children() {
        let store = store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        assert!(
            !store.list_labels().unwrap().is_empty(),
            "backfill stored labels"
        );

        // Must not hit "FOREIGN KEY constraint failed" from the labels table.
        store.delete_account("a1").unwrap();

        assert!(store.list_accounts().unwrap().is_empty());
        assert!(store.list_labels().unwrap().is_empty());
        assert!(store
            .list_threads(None, &ThreadFilter::All, None, 10)
            .unwrap()
            .is_empty());
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
            needs_reply: false,
            follow_up_since: None,
            suggestion: None,
            bundle_id: None,
            labels: vec!["INBOX".to_string()],
            has_attachment: false,
            priority: None,
            triage_label_ids: Vec::new(),
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
            ..Default::default()
        })
        .unwrap();
    }

    fn search(s: &SqliteStore, q: &str) -> Vec<SearchResult> {
        s.search(&heypigeon_core::search::parse(q), 50).unwrap()
    }

    #[test]
    fn search_basic_match_with_snippet() {
        let s = store();
        seed_thread(
            &s,
            "t1",
            "Quarterly report",
            "priya@x.com",
            "numbers attached",
            1000,
            false,
        );
        seed_thread(
            &s,
            "t2",
            "Lunch plans",
            "sam@x.com",
            "pizza on friday",
            2000,
            false,
        );

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
        seed_thread(
            &s,
            "t1",
            "Quarterly report",
            "priya@x.com",
            "numbers attached",
            1000,
            false,
        );

        // typing "quart…" mid-word already matches (search-as-you-type)
        assert_eq!(search(&s, "quart").len(), 1);
        // but only the LAST term is a prefix — earlier terms match whole words
        assert!(search(&s, "quart nothing").is_empty());
        assert_eq!(search(&s, "report numb").len(), 1);
    }

    #[test]
    fn search_is_unread_filter() {
        let s = store();
        seed_thread(
            &s,
            "t1",
            "Budget review",
            "priya@x.com",
            "q3 budget",
            1000,
            true,
        );
        seed_thread(
            &s,
            "t2",
            "Budget draft",
            "sam@x.com",
            "first pass",
            2000,
            false,
        );

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
        seed_thread(
            &s,
            "t1",
            "Budget review",
            "priya@x.com",
            "q3 budget",
            1000,
            false,
        );
        seed_thread(
            &s,
            "t2",
            "Budget draft",
            "sam@x.com",
            "first pass",
            2000,
            false,
        );

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
        seed_thread(
            &s,
            "keep",
            "Invoice due",
            "a@x.com",
            "pay the invoice",
            3000,
            false,
        );
        seed_thread(
            &s,
            "junk-spam",
            "Invoice prize",
            "b@x.com",
            "win an invoice",
            2000,
            false,
        );
        seed_thread(
            &s,
            "junk-trash",
            "Invoice old",
            "c@x.com",
            "stale invoice",
            1000,
            false,
        );
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
            hits.iter()
                .map(|h| h.thread.id.as_str())
                .collect::<Vec<_>>(),
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
        seed_thread(
            &s,
            "t1",
            "Invoice overdue",
            "a@x.com",
            "see attachment",
            now - 60_000,
            false,
        );
        seed_thread(
            &s,
            "t2",
            "Hello",
            "b@x.com",
            "the invoice is attached here",
            now,
            false,
        );
        // identical text, different age — newer first
        seed_thread(
            &s,
            "t3",
            "Standup notes",
            "c@x.com",
            "same text",
            now - 86_400_000 * 30,
            false,
        );
        seed_thread(
            &s,
            "t4",
            "Standup notes",
            "d@x.com",
            "same text",
            now,
            false,
        );
        // filler so bm25's idf term is positive (with a 4-doc corpus where
        // half the docs match, idf is 0 and every score ties at 0)
        for i in 0..4 {
            seed_thread(
                &s,
                &format!("f{i}"),
                "Misc chatter",
                "z@x.com",
                "nothing relevant",
                now - 1_000_000,
                false,
            );
        }

        let hits = search(&s, "invoice");
        assert_eq!(hits.len(), 2);
        assert_eq!(
            hits[0].thread.id, "t1",
            "subject match ranks above body match"
        );

        let hits = search(&s, "standup");
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].thread.id, "t4", "equal relevance → newer wins");
    }

    #[test]
    fn search_diacritics_fold_both_ways() {
        let s = store();
        seed_thread(
            &s,
            "t1",
            "Péter birthday",
            "peter@x.com",
            "cake at five",
            1000,
            false,
        );
        seed_thread(
            &s,
            "t2",
            "Peter standup",
            "peter@x.com",
            "notes",
            2000,
            false,
        );

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
        let dir = std::env::temp_dir().join(format!("heypigeon-test-migr-{}", std::process::id()));
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
        assert_eq!(
            search(&s, "zanzibar").len(),
            1,
            "subject indexed by rebuild"
        );
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

    /// The one-pass counts agree with the per-folder COUNT queries, label
    /// and junk rules included.
    #[test]
    fn unread_counts_agree_with_count_unread() {
        let s = store();
        s.upsert_account(&sample_account("a2")).unwrap();
        s.set_labels(
            &"a1".to_string(),
            &[Label {
                account_id: "a1".into(),
                id: "Label_1".into(),
                name: "Invoices".into(),
            }],
        )
        .unwrap();
        let mk =
            |id: &str, account: &str, labels: &[&str], inbox: bool, archived: bool, read: bool| {
                Thread {
                    id: id.to_string(),
                    account_id: account.to_string(),
                    subject: String::new(),
                    snippet: String::new(),
                    last_msg_at: 1,
                    is_read: read,
                    is_inbox: inbox,
                    is_archived: archived,
                    msg_count: 1,
                    from_summary: "Someone".to_string(),
                    last_from_addr: "someone@example.com".to_string(),
                    scheduled_at: None,
                    needs_reply: false,
                    follow_up_since: None,
                    suggestion: None,
                    bundle_id: None,
                    labels: labels.iter().map(|s| s.to_string()).collect(),
                    has_attachment: false,
                    priority: None,
                    triage_label_ids: Vec::new(),
                }
            };
        for t in [
            mk(
                "inbox-unread",
                "a1",
                &["INBOX", "Label_1"],
                true,
                false,
                false,
            ),
            mk("inbox-read", "a1", &["INBOX"], true, false, true),
            mk("starred", "a1", &["STARRED"], false, false, false),
            mk("archived", "a1", &["Label_1"], false, true, false),
            mk("trashed", "a1", &["TRASH", "Label_1"], false, false, false),
            mk(
                "trashed-inbox",
                "a1",
                &["TRASH", "INBOX"],
                true,
                false,
                false,
            ),
            mk("draft", "a1", &["DRAFT"], false, false, false),
            mk("spam", "a1", &["SPAM"], false, false, false),
            mk(
                "other-account",
                "a2",
                &["INBOX", "STARRED"],
                true,
                false,
                false,
            ),
        ] {
            s.upsert_thread(&t).unwrap();
        }
        s.set_schedule(&"starred".to_string(), Some(5)).unwrap();
        s.set_needs_reply(&"draft".to_string(), true).unwrap();
        for account in [None, Some("a1".to_string()), Some("a2".to_string())] {
            let counts = s.unread_counts(account.as_ref()).unwrap();
            for (key, filter) in ThreadFilter::COUNTED_FOLDERS {
                assert_eq!(
                    counts[key],
                    s.count_unread(account.as_ref(), &filter).unwrap(),
                    "{key} for {account:?}"
                );
            }
            assert_eq!(
                counts["label:Label_1"],
                s.count_unread(account.as_ref(), &ThreadFilter::Label("Label_1".into()))
                    .unwrap()
            );
            assert_eq!(counts.len(), ThreadFilter::COUNTED_FOLDERS.len() + 1);
        }
        let all = s.unread_counts(None).unwrap();
        assert_eq!(
            all["inbox"], 3,
            "inbox-unread, trashed-inbox, other-account"
        );
        assert_eq!(
            all["label:Label_1"], 2,
            "inbox-unread, archived; the trashed one is junk"
        );
        assert_eq!(all["trash"], 2);
    }

    /// A page lands as one commit: everything or, on a bad row, nothing.
    #[test]
    fn upsert_page_is_one_transaction() {
        let s = store();
        let thread = |id: &str| Thread {
            id: id.to_string(),
            account_id: "a1".to_string(),
            subject: id.to_string(),
            snippet: String::new(),
            last_msg_at: 1,
            is_read: false,
            is_inbox: true,
            is_archived: false,
            msg_count: 1,
            from_summary: "Someone".to_string(),
            last_from_addr: "someone@example.com".to_string(),
            scheduled_at: None,
            needs_reply: false,
            follow_up_since: None,
            suggestion: None,
            bundle_id: None,
            labels: vec!["INBOX".to_string()],
            has_attachment: false,
            priority: None,
            triage_label_ids: Vec::new(),
        };
        let message = |id: &str, thread_id: &str, account: &str| Message {
            id: id.to_string(),
            thread_id: thread_id.to_string(),
            account_id: account.to_string(),
            from_addr: "someone@example.com".to_string(),
            to_addrs: vec!["me@example.com".to_string()],
            date: 1,
            snippet: id.to_string(),
            body_html: None,
            body_text: None,
            label_ids: vec!["INBOX".to_string()],
            is_read: false,
            ..Default::default()
        };
        s.upsert_page(&[
            (
                thread("t1"),
                vec![message("m1", "t1", "a1"), message("m2", "t1", "a1")],
            ),
            (thread("t2"), vec![message("m3", "t2", "a1")]),
        ])
        .unwrap();
        assert_eq!(s.list_messages(&"t1".to_string()).unwrap().len(), 2);
        assert_eq!(
            s.list_threads(None, &ThreadFilter::Inbox, None, 10)
                .unwrap()
                .len(),
            2
        );
        // A message for an unknown account breaks the foreign key: the page
        // rolls back, the good thread before it included.
        let bad = s.upsert_page(&[
            (thread("t3"), vec![message("m4", "t3", "a1")]),
            (thread("t4"), vec![message("m5", "t4", "nobody")]),
        ]);
        assert!(bad.is_err());
        assert!(s.get_thread(&"t3".to_string()).unwrap().is_none());
        assert!(s.get_thread(&"t4".to_string()).unwrap().is_none());
    }

    /// A file-backed store reads through its own connection: it sees every
    /// commit, and a write in progress does not make it wait.
    #[test]
    fn reader_sees_commits_and_does_not_wait_for_a_write() {
        let dir =
            std::env::temp_dir().join(format!("heypigeon-test-reader-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mail.db");
        let _ = std::fs::remove_file(&path);
        let s = std::sync::Arc::new(SqliteStore::open(&path).unwrap());
        assert!(!s.readers.is_empty());
        s.upsert_account(&sample_account("a1")).unwrap();
        let mk = |id: &str| Thread {
            id: id.to_string(),
            account_id: "a1".to_string(),
            subject: id.to_string(),
            snippet: String::new(),
            last_msg_at: 1,
            is_read: false,
            is_inbox: true,
            is_archived: false,
            msg_count: 1,
            from_summary: "Someone".to_string(),
            last_from_addr: "someone@example.com".to_string(),
            scheduled_at: None,
            needs_reply: false,
            follow_up_since: None,
            suggestion: None,
            bundle_id: None,
            labels: vec!["INBOX".to_string()],
            has_attachment: false,
            priority: None,
            triage_label_ids: Vec::new(),
        };
        s.upsert_thread(&mk("t1")).unwrap();
        // Read-your-write across the two connections.
        assert_eq!(
            s.list_threads(None, &ThreadFilter::Inbox, None, 10)
                .unwrap()
                .len(),
            1
        );
        assert_eq!(s.unread_counts(None).unwrap()["inbox"], 1);

        // A write transaction stays open on the writer for a while; the
        // reader answers meanwhile, from the last commit.
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let writer = std::sync::Arc::clone(&s);
        let hold = std::thread::spawn(move || {
            writer
                .with(|c| {
                    let tx = c.unchecked_transaction()?;
                    upsert_thread_on(&tx, &mk("t2"))?;
                    started_tx.send(()).unwrap();
                    std::thread::sleep(std::time::Duration::from_millis(400));
                    tx.commit()
                })
                .unwrap();
        });
        started_rx.recv().unwrap();
        let began = std::time::Instant::now();
        let seen = s
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap();
        assert!(
            began.elapsed() < std::time::Duration::from_millis(300),
            "the read waited on the write"
        );
        assert_eq!(seen.len(), 1, "the uncommitted thread is not visible yet");
        hold.join().unwrap();
        assert_eq!(
            s.list_threads(None, &ThreadFilter::Inbox, None, 10)
                .unwrap()
                .len(),
            2
        );
        drop(s);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- v22–v25: message headers, the label index, the stale indexes

    /// Thread ids of a view in the order the store lists them.
    fn ordered(s: &SqliteStore, f: &ThreadFilter) -> Vec<String> {
        s.list_threads(None, f, None, 100)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect()
    }

    fn plan(s: &SqliteStore, sql: &str, params: impl rusqlite::Params) -> String {
        s.with(|c| {
            let mut stmt = c.prepare(&format!("EXPLAIN QUERY PLAN {sql}"))?;
            let rows = stmt.query_map(params, |r| r.get::<_, String>(3))?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?.join(" | "))
        })
        .unwrap()
    }

    /// The upgrade every existing install takes: a v21 database with mail
    /// in it. The old rows keep everything they had, read as "not fetched
    /// in full yet", and are in the label index the moment it exists.
    #[test]
    fn v21_database_upgrades_in_place() {
        let dir = std::env::temp_dir().join(format!("heypigeon-test-v22-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v21.db");
        let _ = std::fs::remove_file(&path);
        {
            let conn = Connection::open(&path).unwrap();
            let _ = SqliteStore::init_to(conn, 21).unwrap();
        }
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                r#"
                INSERT INTO accounts (id, email, display_name, color, history_id)
                VALUES ('a1', 'a1@example.com', 'A1', 'sky', 'hist-1');
                INSERT INTO threads (id, account_id, subject, snippet, last_msg_at, is_read,
                                     is_inbox, is_archived, msg_count, from_summary,
                                     last_from_addr, labels, has_attachment)
                VALUES ('t1', 'a1', 'Quarterly numbers', 'snip', 2000, 0, 1, 0, 1, 'Priya',
                        'priya@x.com', '["INBOX","STARRED","Label_7","UNREAD"]', 0),
                       ('t2', 'a1', 'Sent thing', 'snip', 1000, 1, 0, 0, 1, 'Sam',
                        'sam@x.com', '["SENT"]', 0);
                INSERT INTO messages (id, thread_id, account_id, from_addr, to_addrs, date,
                                      snippet, body_html, body_text, label_ids, is_read)
                VALUES ('m1', 't1', 'a1', 'Priya <priya@x.com>', '["a1@example.com"]', 2000,
                        'snip', '<p>zanzibar</p>', 'zanzibar itinerary',
                        '["INBOX","STARRED","Label_7","UNREAD"]', 0),
                       ('m2', 't2', 'a1', 'a1@example.com', '["sam@x.com"]', 1000,
                        'snip', NULL, NULL, '["SENT"]', 1);
                INSERT INTO labels (account_id, id, name) VALUES ('a1', 'Label_7', 'Work');
                INSERT INTO outbox (account_id, mutation, attempts, created_at)
                VALUES ('a1', '{"kind":"send","to":["sam@x.com"],"subject":"s","body_text":"b"}',
                        2, 1);
                "#,
            )
            .unwrap();
        }
        let s = SqliteStore::open(&path).unwrap(); // runs v22..
        let version: i64 = s
            .with(|c| c.pragma_query_value(None, "user_version", |r| r.get(0)))
            .unwrap();
        assert_eq!(version as usize, MIGRATIONS.len());

        // Old messages: bodies kept, new columns at their defaults.
        let m = s.list_messages(&"t1".to_string()).unwrap().remove(0);
        assert_eq!(m.body_text.as_deref(), Some("zanzibar itinerary"));
        assert_eq!(m.body_html.as_deref(), Some("<p>zanzibar</p>"));
        assert!(m.cc_addrs.is_empty() && m.message_id_header.is_none());
        assert!(m.list_unsubscribe.is_none() && !m.list_unsubscribe_one_click);
        // On purpose: the next open fetches the thread once more, which is
        // what fills Cc / Message-ID / List-Unsubscribe for old mail.
        assert!(!m.body_fetched);
        assert!(heypigeon_core::sync::needs_bodies(std::slice::from_ref(&m)));

        // The label index was filled for the mail that was already there.
        assert_eq!(ids(&s, &ThreadFilter::Starred), vec!["t1"]);
        assert_eq!(ids(&s, &ThreadFilter::Label("Label_7".into())), vec!["t1"]);
        assert_eq!(ids(&s, &ThreadFilter::Sent), vec!["t2"]);
        assert_eq!(ids(&s, &ThreadFilter::All), vec!["t1", "t2"]);
        assert_eq!(s.unread_counts(None).unwrap()["label:Label_7"], 1);
        assert_eq!(s.unread_counts(None).unwrap()["starred"], 1);

        // Search still finds the old body, and follows the full fetch.
        let q = heypigeon_core::search::parse("zanzibar");
        assert_eq!(s.search(&q, 10).unwrap().len(), 1);
        let mut full = m;
        full.cc_addrs = vec!["Lee <lee@x.com>".to_string()];
        full.message_id_header = Some("<m1@x.com>".to_string());
        full.body_fetched = true;
        s.upsert_message(&full).unwrap();
        let after = s.list_messages(&"t1".to_string()).unwrap().remove(0);
        assert!(after.body_fetched);
        assert_eq!(after.cc_addrs, vec!["Lee <lee@x.com>"]);
        assert_eq!(s.search(&q, 10).unwrap().len(), 1);

        // A queued send from the old build still reads, attempts kept.
        let queued = s.outbox_list(10).unwrap();
        assert_eq!(queued.len(), 1);
        assert_eq!(queued[0].attempts, 2);
        assert!(matches!(
            queued[0].mutation,
            Mutation::Send {
                from_addr: None,
                in_reply_to: None,
                ..
            }
        ));

        // And it opens again at the new version without running anything.
        drop(s);
        let s = SqliteStore::open(&path).unwrap();
        assert_eq!(ids(&s, &ThreadFilter::Starred), vec!["t1"]);
        let _ = std::fs::remove_file(&path);
    }

    /// A migration step is one transaction: when a statement in it fails,
    /// nothing of the step stays and the version does not move.
    #[test]
    fn a_failed_migration_step_leaves_the_old_version() {
        let conn = Connection::open_in_memory().unwrap();
        // The step that adds `thread_labels` cannot run if the table exists.
        conn.execute_batch("CREATE TABLE thread_labels (x)")
            .unwrap();
        assert!(SqliteStore::init_to(conn, MIGRATIONS.len()).is_err());

        let conn = Connection::open_in_memory().unwrap();
        let s = SqliteStore::init_to(conn, 23).unwrap();
        s.with(|c| c.execute_batch("CREATE TABLE thread_labels (x)"))
            .unwrap();
        let conn = s.conn.into_inner().unwrap();
        assert!(SqliteStore::init_to(conn, MIGRATIONS.len()).is_err());
    }

    #[test]
    fn label_views_follow_the_threads_labels() {
        let s = store();
        s.upsert_account(&sample_account("a1")).unwrap();
        seed_labelled(&s, "t1", &["INBOX", "Label_1"], true, false, 3000);
        seed_labelled(&s, "t2", &["Label_1", "STARRED"], false, true, 2000);
        seed_labelled(&s, "t3", &["Label_1", "TRASH"], false, false, 1000);
        let label = ThreadFilter::Label("Label_1".into());
        // Newest first; the trashed one is junk.
        assert_eq!(ordered(&s, &label), vec!["t1", "t2"]);
        assert_eq!(ids(&s, &ThreadFilter::Trash), vec!["t3"]);
        // Keyset page: strictly older than t1.
        let page: Vec<String> = s
            .list_threads(None, &label, Some(3000), 1)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
        assert_eq!(page, vec!["t2"]);
        // Another account's view of the same label id is empty.
        assert!(s
            .list_threads(Some(&"other".to_string()), &label, None, 10)
            .unwrap()
            .is_empty());

        // An optimistic star and a label flip move rows in and out at once.
        s.apply_local(&Mutation::Star {
            thread_id: "t1".into(),
            starred: true,
        })
        .unwrap();
        assert_eq!(ordered(&s, &ThreadFilter::Starred), vec!["t1", "t2"]);
        s.apply_local(&Mutation::ModifyLabel {
            thread_id: "t2".into(),
            label_id: "Label_1".into(),
            add: false,
        })
        .unwrap();
        assert_eq!(ordered(&s, &label), vec!["t1"]);
        // A sync re-upsert with a newer message re-sorts the thread.
        seed_labelled(&s, "t2", &["Label_1", "STARRED"], false, true, 9000);
        assert_eq!(ordered(&s, &label), vec!["t2", "t1"]);
        // Deleting the thread, or the label, leaves nothing behind.
        s.delete_thread(&"t1".to_string()).unwrap();
        s.delete_label("a1", "Label_1").unwrap();
        assert!(ids(&s, &label).is_empty());
        let left: i64 = s
            .with(|c| {
                c.query_row(
                    "SELECT COUNT(*) FROM thread_labels WHERE label_id = 'Label_1'
                        OR thread_id = 't1'",
                    [],
                    |r| r.get(0),
                )
            })
            .unwrap();
        assert_eq!(left, 0);
    }

    #[test]
    fn untrash_and_spam_move_between_folders_locally() {
        let s = store();
        s.upsert_account(&sample_account("a1")).unwrap();
        seed_labelled(&s, "t1", &["INBOX", "Label_1"], true, false, 1000);
        let t1 = "t1".to_string();

        s.apply_local(&Mutation::Trash {
            thread_id: t1.clone(),
        })
        .unwrap();
        assert_eq!(ids(&s, &ThreadFilter::Trash), vec!["t1"]);
        s.apply_local(&Mutation::Untrash {
            thread_id: t1.clone(),
        })
        .unwrap();
        assert!(ids(&s, &ThreadFilter::Trash).is_empty());
        assert_eq!(ids(&s, &ThreadFilter::Inbox), vec!["t1"]);

        s.apply_local(&Mutation::MarkSpam {
            thread_id: t1.clone(),
            spam: true,
        })
        .unwrap();
        assert_eq!(ids(&s, &ThreadFilter::Spam), vec!["t1"]);
        assert!(ids(&s, &ThreadFilter::Inbox).is_empty());
        assert!(ids(&s, &ThreadFilter::All).is_empty());
        let t = s.get_thread(&t1).unwrap().unwrap();
        assert!(!t.is_inbox && !t.is_archived);

        s.apply_local(&Mutation::MarkSpam {
            thread_id: t1.clone(),
            spam: false,
        })
        .unwrap();
        assert!(ids(&s, &ThreadFilter::Spam).is_empty());
        assert_eq!(ids(&s, &ThreadFilter::Inbox), vec!["t1"]);
        // The user's own label came through all of it.
        assert_eq!(ids(&s, &ThreadFilter::Label("Label_1".into())), vec!["t1"]);
    }

    /// Each list view reads through an index that already has its order:
    /// no whole-table scan, no sort.
    #[test]
    fn list_and_stale_queries_use_their_indexes() {
        let s = store();
        let none: Option<String> = None;
        let expect = |filter: ThreadFilter, index: &str| {
            let (sql, label) = list_threads_sql(&filter);
            let p = match label {
                Some(id) => plan(&s, &sql, params![none, None::<i64>, 50, id]),
                None => plan(&s, &sql, params![none, None::<i64>, 50]),
            };
            assert!(p.contains(index), "{filter:?}: {p}");
            assert!(!p.contains("TEMP B-TREE"), "{filter:?} sorts: {p}");
            // Walking an index in order is fine; reading the bare table is not.
            assert!(
                !p.replace("SCAN t USING INDEX", "").contains("SCAN t"),
                "{filter:?}: {p}"
            );
        };
        expect(ThreadFilter::Inbox, "idx_threads_list");
        expect(ThreadFilter::Archive, "idx_threads_time");
        expect(ThreadFilter::All, "idx_threads_time");
        for f in [
            ThreadFilter::Starred,
            ThreadFilter::Sent,
            ThreadFilter::Drafts,
            ThreadFilter::Spam,
            ThreadFilter::Trash,
            ThreadFilter::Label("Label_1".into()),
        ] {
            expect(f, "SEARCH tl USING PRIMARY KEY (label_id=?");
        }

        let p = plan(&s, &needing_anchors_sql(), params![500]);
        assert!(
            p.contains("idx_threads_anchors_stale") && !p.contains("TEMP B-TREE"),
            "{p}"
        );
        let p = plan(&s, &needing_triage_sql(), params![10]);
        assert!(
            p.contains("idx_threads_triage_stale") && !p.contains("TEMP B-TREE"),
            "{p}"
        );
        let p = plan(&s, &count_needing_triage_sql(), params![0]);
        assert!(p.contains("idx_threads_triage_stale"), "{p}");
    }

    /// Size of the search index's own storage: it grows whenever a message
    /// is (re)indexed.
    fn fts_bytes(s: &SqliteStore) -> i64 {
        s.with(|c| {
            c.query_row(
                "SELECT COALESCE(SUM(LENGTH(block)), 0) + COUNT(*) FROM messages_fts_data",
                [],
                |r| r.get(0),
            )
        })
        .unwrap()
    }

    /// A re-upsert that changes labels or read state (what every delta
    /// round does to a thread's messages) leaves the search index alone
    /// and loses nothing a fuller fetch stored.
    #[test]
    fn metadata_reupsert_keeps_fetched_state_and_does_not_reindex() {
        let s = store();
        seed_thread(
            &s,
            "t1",
            "Hello",
            "a@x.com",
            "zanzibar itinerary",
            1000,
            false,
        );
        let t1 = "t1".to_string();
        let mut full = s.list_messages(&t1).unwrap().remove(0);
        full.cc_addrs = vec!["\"Doe, Jane\" <jane@x.com>".to_string()];
        full.message_id_header = Some("<m1@x.com>".to_string());
        full.references_header = Some("<m0@x.com>".to_string());
        full.list_unsubscribe = Some("<https://x.com/u>".to_string());
        full.list_unsubscribe_one_click = true;
        full.body_fetched = true;
        s.upsert_message(&full).unwrap();
        let indexed = fts_bytes(&s);

        // The sync loop's shape: read without bodies, flip a label, write.
        let mut meta = s.list_message_meta(&t1).unwrap().remove(0);
        assert!(meta.body_text.is_none() && meta.body_html.is_none());
        assert!(meta.body_fetched);
        meta.label_ids = vec!["INBOX".to_string(), "STARRED".to_string()];
        meta.is_read = true;
        s.upsert_message(&meta).unwrap();
        // And a metadata-tier snapshot from the provider, which knows
        // nothing of the body or the fetch.
        let bare = Message {
            id: full.id.clone(),
            thread_id: t1.clone(),
            account_id: full.account_id.clone(),
            from_addr: full.from_addr.clone(),
            to_addrs: full.to_addrs.clone(),
            date: full.date,
            snippet: full.snippet.clone(),
            label_ids: vec!["INBOX".to_string()],
            ..Default::default()
        };
        s.upsert_message(&bare).unwrap();

        assert_eq!(
            fts_bytes(&s),
            indexed,
            "label and read changes must not reindex"
        );
        let stored = s.list_messages(&t1).unwrap().remove(0);
        assert_eq!(stored.body_text.as_deref(), Some("zanzibar itinerary"));
        assert!(stored.body_fetched && stored.list_unsubscribe_one_click);
        assert_eq!(stored.cc_addrs, full.cc_addrs);
        assert_eq!(stored.message_id_header, full.message_id_header);
        assert_eq!(stored.references_header, full.references_header);
        assert_eq!(stored.list_unsubscribe, full.list_unsubscribe);
        assert_eq!(stored.label_ids, vec!["INBOX"]);

        // A changed body is still followed.
        let mut edited = stored;
        edited.body_text = Some("madagascar itinerary".to_string());
        s.upsert_message(&edited).unwrap();
        assert_ne!(fts_bytes(&s), indexed);
        assert_eq!(search(&s, "madagascar").len(), 1);
        assert!(search(&s, "zanzibar").is_empty());
    }

    #[test]
    fn bundle_stats_agree_with_the_listed_threads() {
        let s = store();
        s.upsert_account(&sample_account("a1")).unwrap();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 3000);
        seed_labelled(&s, "t2", &[], false, true, 2000);
        seed_labelled(&s, "t3", &["TRASH"], false, false, 9000);
        seed_labelled(&s, "t4", &["INBOX"], true, false, 500);
        let bundle = |id: &str| Bundle {
            id: id.to_string(),
            name: id.to_string(),
            kind: BundleKind::Trip,
            description: String::new(),
            status: BundleStatus::Active,
            origin: BundleOrigin::User,
            created_at: 1,
            updated_at: 1,
        };
        s.upsert_bundle(&bundle("b1")).unwrap();
        s.upsert_bundle(&bundle("empty")).unwrap();
        for t in ["t1", "t2", "t3"] {
            s.set_thread_bundle(&t.to_string(), Some(("b1", BundleSource::User)))
                .unwrap();
        }

        let stats = s.bundle_stats().unwrap();
        let listed = s.list_bundle_threads("b1").unwrap();
        assert_eq!(listed.len(), 2, "the trashed thread does not show");
        assert_eq!(
            stats["b1"],
            BundleStats {
                thread_count: 2,
                open_count: 1,
                last_activity_at: 3000,
            }
        );
        assert!(!stats.contains_key("empty"));
    }

    #[test]
    fn outbox_ids_due_rows_and_counts() {
        let s = store();
        s.upsert_account(&sample_account("a1")).unwrap();
        let a1 = "a1".to_string();
        let archive = |t: &str| Mutation::Archive {
            thread_id: t.to_string(),
        };
        let first = s.outbox_push(&a1, &archive("t1")).unwrap();
        let second = s.outbox_push(&a1, &archive("t2")).unwrap();
        let third = s.outbox_push(&a1, &archive("t3")).unwrap();
        assert!(first < second && second < third);
        for _ in 0..3 {
            s.outbox_bump_attempts(first).unwrap();
        }

        // `first` reached the cap of 3: kept, not due.
        let due: Vec<i64> = s
            .outbox_list_due(0, 10, 3)
            .unwrap()
            .into_iter()
            .map(|i| i.id)
            .collect();
        assert_eq!(due, vec![second, third]);
        let next: Vec<i64> = s
            .outbox_list_due(second, 10, 3)
            .unwrap()
            .into_iter()
            .map(|i| i.id)
            .collect();
        assert_eq!(next, vec![third]);
        assert_eq!(s.outbox_counts(3).unwrap(), (2, 1));
        assert_eq!(s.outbox_list(10).unwrap().len(), 3);
        assert!(s.outbox_contains(first).unwrap());
        s.outbox_delete(second).unwrap();
        assert!(!s.outbox_contains(second).unwrap());
        assert_eq!(s.outbox_counts(3).unwrap(), (1, 1));
        assert_eq!(
            SqliteStore::open_in_memory()
                .unwrap()
                .outbox_counts(3)
                .unwrap(),
            (0, 0)
        );
    }

    #[test]
    fn anchors_batch_is_one_write_for_many_threads() {
        let s = store();
        s.upsert_account(&sample_account("a1")).unwrap();
        seed_labelled(&s, "t1", &["INBOX"], true, false, 2000);
        seed_labelled(&s, "t2", &["INBOX"], true, false, 1000);
        assert_eq!(s.list_threads_needing_anchors(10).unwrap().len(), 2);
        s.set_thread_anchors(&"t1".to_string(), &["order:OLD".to_string()], 1)
            .unwrap();

        s.set_thread_anchors_batch(&[
            ("t1".to_string(), vec!["order:1".to_string()], 1),
            ("t2".to_string(), vec![], 1),
        ])
        .unwrap();

        assert_eq!(
            s.thread_anchors(&"t1".to_string()).unwrap(),
            vec!["order:1"]
        );
        assert!(s.thread_anchors(&"t2".to_string()).unwrap().is_empty());
        assert!(s.list_threads_needing_anchors(10).unwrap().is_empty());
    }

    #[test]
    fn correspondents_group_the_stored_mail() {
        let s = store();
        seed_thread(&s, "t1", "Hello", "Priya <priya@x.com>", "hi", 1000, false);
        seed_thread(&s, "t2", "Again", "Priya <priya@x.com>", "hi", 3000, false);
        let mut sent = s.list_messages(&"t1".to_string()).unwrap().remove(0);
        sent.id = "sent-1".to_string();
        sent.from_addr = "a1@example.com".to_string();
        sent.to_addrs = vec!["Sam <sam@x.com>".to_string()];
        sent.cc_addrs = vec!["lee@x.com".to_string()];
        sent.label_ids = vec!["SENT".to_string()];
        sent.date = 2000;
        s.upsert_message(&sent).unwrap();

        let mut rows = s.correspondents().unwrap();
        rows.sort_by_key(|r| r.sent);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].from_addr, "Priya <priya@x.com>");
        assert_eq!(
            (rows[0].count, rows[0].last_at, rows[0].sent),
            (2, 3000, false)
        );
        assert_eq!(rows[1].to_addrs, vec!["Sam <sam@x.com>"]);
        assert_eq!(rows[1].cc_addrs, vec!["lee@x.com"]);
        assert!(rows[1].sent);
    }
}
