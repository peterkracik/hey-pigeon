# Pigeon — Design Doc

A minimalist, keyboard-first Gmail client. Superhuman feel, $0 to run, open-sourceable.
Client-only: no server, all data local.

> Name: **Pigeon** (working title was "vibemail"). Domain: **heypigeon.app**.
> One bird carrying your mail — personal tool, not an Outlook replacement.

## Why

Superhuman is great but expensive. Its magic is not the features — it's that every
action is instant. That comes from local-first architecture: the whole mailbox lives
in a local DB, the UI never waits for the network. That's the one thing Pigeon
must get right. Everything else is optional.

## Goals (v1)

- **2+ Gmail accounts** from day one, unified inbox (per-account filter a keystroke away).
- **Instant everything**: open, archive, search — 0ms perceived, network happens in background.
- **Keyboard-first**: j/k navigate, e archive, enter open, / search, cmd+k palette, 1/2/0 account switch.
- **Minimalist UI**: an email list that looks like a beautiful todo list. References:
  Google Inbox, Newton Mail, Superhuman, Things 3.
- Read, triage (archive, mark read/unread, trash), search. Compose/reply in v1.1.

## Non-goals (v1)

- Generic IMAP (Gmail API only — IMAP is where email clients go to die).
- Compose/send (v1.1: `messages.send` is easy once reading works).
- Snooze, send-later, snippets, read receipts, split inbox, calendar.
- Server infrastructure of any kind. AI included: calls go straight from the app to
  the provider with the user's own API key.
- AI in v1 core (it lands in M3, after reading/triage feel right).

## Architecture

```text
┌───────────────────────────── Tauri 2 app ─────────────────────────────┐
│                                                                        │
│  Rust core                                    Web frontend (Svelte)    │
│  ┌──────────────────────────────┐             ┌─────────────────────┐  │
│  │ auth: OAuth 2 PKCE           │  Tauri IPC  │ thread list         │  │
│  │   loopback flow, per account │◄───────────►│ thread view         │  │
│  │   tokens → OS keychain       │  (commands  │ command palette     │  │
│  │ sync: per-account loop       │   + events) │ keyboard controller │  │
│  │   backfill + history deltas  │             └─────────────────────┘  │
│  │ store: SQLite + FTS5         │                                      │
│  └──────────────────────────────┘                                      │
│                     │                                                  │
└─────────────────────┼──────────────────────────────────────────────────┘
                      ▼
               Gmail REST API (per account)
```

- **Tauri 2** — chosen over Electron (lighter) and native Swift (slower iteration).
  Decisive: Tauri 2 ships to **iOS and Android** from the same codebase — see iOS section.
- **Rust core** owns all state: OAuth, sync, SQLite. The frontend is a dumb, fast view.
- **Svelte** frontend — lean output, fits the minimalist ethos.
- UI reads via Tauri commands (query SQLite), receives change events (new mail, sync
  status) via Tauri events. UI **never** talks to Gmail directly.

### Optimistic mutations

Archive/read/trash apply to SQLite immediately, UI updates instantly, and the Gmail
API call is queued (outbox table, retried with backoff). This is the entire "feels
instant" trick. Conflicts are resolved by last-writer-wins; Gmail's history feed
corrects drift.

## Multi-account (2 from day one)

- `accounts` table; every message/thread row carries `account_id`.
- One independent sync loop per account (failure in one never blocks the other).
- Unified inbox = a query across accounts, sorted by date. Filter to one account with
  `1` / `2`; `0` = unified. Account badge (colored dot) on each row in unified view.
- Compose-later note: replies must send from the receiving account by default.

## Auth

- OAuth 2 **PKCE loopback** flow (native-app flow, no client secret): open browser,
  Google consent, redirect to `http://127.0.0.1:<port>`, exchange code locally.
- Refresh tokens in the **OS keychain** (Keychain on macOS/iOS), never in SQLite.
- Scopes: `gmail.modify` (read + label changes; superset needed for archive).
  v1.1 adds `gmail.send`.
- Open-source distribution wrinkle: users bring their own Google OAuth client ID
  (documented 5-minute setup), or the project ships a shared client ID and goes
  through Google verification later. v1: bring-your-own, it's for Peter first.

## Sync engine

Per account:

1. **Backfill**: `threads.list` newest-first (INBOX first, then All Mail), fetch with
   `format=metadata` for list rendering + separately fetch bodies lazily or in a
   low-priority queue. Last 90 days first, older pages later. Store the profile's
   `historyId` **before** starting backfill.
2. **Delta loop**: poll `history.list(startHistoryId)` every ~30s (and on app focus).
   Apply message added/deleted/label-changed. Cheap: empty response when nothing new.
3. **Recovery**: if `historyId` is too old (Gmail 404s), re-run backfill. Idempotent
   upserts make this safe.
4. **Outbox drain**: apply queued local mutations (`messages.batchModify`) with
   exponential backoff; on success remove from outbox.

### Push notifications (new-mail latency)

Three tiers — still no server:

1. **v1 — polling**: `history.list` every ~30s + immediately on app focus/wake.
   One cheap request per account; empty response when nothing new. For a mail client
   this is indistinguishable from push in practice.
2. **v1.x — real push, still serverless**: Gmail `users.watch` publishes to a
   Cloud **Pub/Sub topic**, and the desktop client consumes it via a **streaming
   pull subscription** — no public webhook, no server. Works because bring-your-own
   OAuth client already means the user has their own GCP project; the topic lives
   there. Costs: topic setup in the onboarding doc, `watch` renewal every 7 days
   (piggyback on the sync loop), Pub/Sub scope. Slot behind a `PushChannel` port
   with the poller as default adapter.
3. **iOS (M4+) — the one true server case**: a suspended iOS app can't hold a
   streaming pull; real iOS notifications need APNs, i.e. a tiny relay
   (watch → Pub/Sub → relay → APNs). That relay sees only "account X has history Y"
   metadata, never mail content. Optional, self-hostable, only for iOS users.

Desktop notification itself: OS notification via Tauri plugin, from the sync loop
diff (new INBOX message → notify sender + subject; respect per-account mute).

Bodies: store sanitized HTML + plain text. Attachments fetched on demand, cached on
disk. Inline images proxied through the core (privacy: block remote images by
default, per-sender allow).

### Large mailboxes (5+ years, 100k–500k messages)

Scale reality: SQLite is comfortable into the tens of millions of rows — message
*count* is a non-issue. The actual constraints are disk (bodies), backfill time
(API quota), and list rendering. Handled by tiering:

| Tier | What | How much |
| --- | --- | --- |
| Metadata + snippet | **every** message, forever | ~1 KB/msg → a few hundred MB for 500k — keep all |
| Bodies | recent window hot + on-demand for old | zstd-compressed blobs (~3–5× smaller); LRU cache with a configurable cap (default ~5 GB) |
| Attachments | on demand only | LRU disk cache |

- **Progressive backfill**: 90 days first (usable in minutes), then a low-priority
  background walk pages through the full archive — oldest mail arrives over hours,
  app fully usable throughout. Quota math: batched `messages.get` ≈ 50 msgs/s
  sustainable → 100k messages ≈ 30–60 min; 500k ≈ overnight. One-time cost per
  account, checkpointed (`sync_state` stores the backfill cursor) so it resumes
  after quit/crash.
- **Old mail on demand**: opening a 2019 thread without a local body fetches it
  live (~300 ms, spinner in the thread view only), then caches it. Metadata is
  local, so the *list* is always instant.
- **Search over everything**: subject/from/to are FTS-indexed for all 500k (they're
  metadata). Body search covers messages whose body is local; older hits fall
  through to Gmail `q=` merged below local results (see Search section).
- **List rendering**: virtualized list + keyset pagination (`WHERE last_msg_at < ?
  ORDER BY last_msg_at DESC LIMIT 200`), never `OFFSET` — scroll position 400k
  threads deep costs the same as page one.
- **Optional "full archive" mode**: a settings toggle to download + index every body
  locally (full offline search, more disk). Default stays tiered.

### Attachments

Same tiering philosophy: **metadata always, bytes on demand.**

- **Metadata** (filename, MIME type, size, `gmail_attachment_id`) is captured during
  sync into the `attachments` table — costs nothing, enables `has:attachment` /
  `filename:` search (filenames go into the FTS index) and attachment chips in the
  list/thread view without any download.
- **Bytes** are fetched only when the user clicks: `messages.attachments.get` →
  content-addressed file in the disk cache (`cache/attachments/<sha256>`), part of
  the same LRU cap as bodies. Second click is instant.
- **Viewing**: chip click → fetch → open with the OS (Quick Look / default app).
  Inline preview inside the app only for images (they're already sandbox-rendered);
  everything else delegates to the OS — no PDF viewer to write or secure.
- **Saving**: "Save to Downloads" + drag the chip out of the window (Tauri
  drag-out). Filename sanitized (path separators, leading dots stripped); on macOS
  the quarantine attribute stays on so Gatekeeper does its job.
- **Security** (restating from Security section): never auto-open, never execute,
  no preview execution of unknown types.
- **Inline images** (`cid:` parts) are treated as part of the body render, not as
  attachments — fetched with the body, subject to the same remote-image rules.
- **Compose side (v1.1)**: outbox payload references local file paths; upload via
  multipart `messages.send`. Size guard at Gmail's 25 MB limit with a clear error.
- **iOS note**: same model works — cache lives in the app container, `local_path`
  stays relative to the cache root so the DB survives container moves.

## Data model (SQLite)

```sql
accounts   (id, email, display_name, color, history_id, sync_state)
threads    (id, account_id, snippet, subject, last_msg_at, is_read,
            is_inbox, is_archived, msg_count, from_summary)
messages   (id, thread_id, account_id, from_addr, to_addrs, date,
            snippet, body_html, body_text, label_ids, is_read)
labels     (id, account_id, name, type)
attachments(id, message_id, account_id, filename, mime_type, size,
            gmail_attachment_id, local_path)   -- metadata always; bytes on demand
outbox     (id, account_id, kind, payload, attempts, created_at)
messages_fts (FTS5: subject, from, to, body_text)  -- instant local search
```

IDs are Gmail's native IDs, prefixed with account id internally. All writes are
idempotent upserts keyed on (account_id, gmail_id).

### Search

No external search engine — **FTS5 is the search engine**: embedded, BM25-ranked,
millions of rows at millisecond latency, works on iOS, zero moving parts.

- **Index**: `messages_fts(subject, from_addr, to_addrs, body_text)` — contentless
  table synced by triggers on `messages`. `unicode61` tokenizer with
  `remove_diacritics 2` (Péter matches Peter).
- **Search-as-you-type**: last term gets `*` (prefix query); results re-query on
  every keystroke — local, so it's instant. Debounce is unnecessary.
- **Ranking**: `bm25()` with column weights (subject > from > body), blended with
  recency (newer mail wins ties) — the Superhuman trick.
- **Operators**: parse `from:`, `to:`, `label:`, `is:unread`, `has:attachment`,
  `account:` into SQL filters before the FTS match; bare text goes to FTS. Same
  syntax as Gmail so muscle memory transfers.
- **Snippets**: FTS5 `snippet()` for the highlighted preview line in results.
- Fuzzy/typo tolerance: skipped — prefix matching covers the real use case
  ("searching while typing"), add trigram fallback only if it ever hurts.
- Escape hatch: searches older than local backfill can fall through to a
  `MailProvider.search()` call (Gmail `q=`) merged below local results — M4+.

## AI features (BYO key, provider-pluggable, ChatGPT first)

Still no server: the Rust core calls the provider API directly with the **user's own
API key**, stored in the OS keychain next to the OAuth tokens.

**Providers are pluggable by design** — OpenAI ships first, more will be added.
Everything AI-facing is written against one core trait, never against OpenAI:

```rust
trait AiProvider {
    fn id(&self) -> &str;                       // "openai", "anthropic", "ollama", ...
    fn models(&self) -> Vec<ModelInfo>;          // selectable models + default
    fn complete(&self, req: CompletionRequest) -> impl Stream<Item = Token>;
}
```

- **Registry**: providers register by id; settings store `(provider_id, model, key
  → keychain)` per configured provider. User can configure several and pick an
  active one (later: per-feature override, e.g. cheap model for summaries).
- Features (summarize, draft, ask) call the active provider through the trait —
  adding a provider later touches one new file, zero feature code.
- Most future providers (Anthropic aside) speak the OpenAI-compatible chat API, so
  implementation #2 is mostly a base-URL + auth-header variant.
- Settings: paste key, pick provider + model (default a `gpt-4o-mini`-class model
  for cost).
- **v1 AI set (M3)**:
  - **Summarize thread** (`s` in thread view) — one-paragraph TL;DR.
  - **Draft reply** — generate a reply draft in the user's tone into the composer;
    user always edits/sends, never auto-send.
  - **Ask AI** via cmd+k — free-form question grounded in the open thread.
- **Privacy rules**: email content leaves the machine **only** on an explicit AI
  action, never in the background. No AI provider sees anything unless the user
  pressed the button. State this in the UI the first time.
- Cost is the user's own (pennies at personal volume). Show token/cost estimate in
  settings later, not in v1.

## UI spec (brief for the designer)

**One idea: an inbox that looks and feels like an elegant todo list.**
Archiving an email should feel like checking off a task.

- **Single column list**, generous whitespace, typography does all the work.
  Row: `[account dot] sender — subject · one-line preview · time`. Unread = bold
  sender + subtle accent bar, not a sea of bold.
- **No chrome**: no toolbar, no folder tree, no icon rows. Labels/folders live behind
  the command palette. At most: a thin header (current view name + sync dot) and the list.
- **Thread view**: replaces the list (or slides over on narrow widths), latest message
  expanded, older collapsed to single rows. Esc back. Reading is centered, measure
  ~65ch.
- **Command palette (cmd+k)**: the only menu in the app. Search, go-to-label, actions.
- **States**: empty inbox is a designed moment (Superhuman-style calm, not a shrug).
  Loading = skeleton rows, never spinners in the list.
- **Motion**: archive = row slides out ~150ms; that's nearly the only animation.
- **Theme**: light + dark from day one; system-follows.
- References: Google Inbox (card calm), Newton (typography-only rows), Things 3
  (spacing, restraint), Superhuman (speed cues, palette).

### Keyboard map (v1)

| Key | Action |
| --- | --- |
| j / k, ↓ / ↑ | next / previous thread |
| enter | open thread |
| esc | back / close palette |
| e | archive |
| u | mark read/unread |
| # | trash |
| / | search |
| cmd+k | command palette |
| 0 / 1 / 2 | unified / account 1 / account 2 |
| g i / g a | go inbox / go archive |

## iOS (future, shapes v1 decisions)

Tauri 2 builds for iOS. To keep that door open, v1 must:

- Keep **all** logic in the Rust core; frontend stays a pure view (no fs/network in JS).
- Use Tauri plugins with mobile support for keychain/opener; no desktop-only APIs in
  core paths (loopback OAuth redirect becomes a custom URL scheme on iOS — isolate
  the redirect-listener behind a trait now).
- Responsive layout from day one (the narrow "thread view replaces list" behavior is
  exactly the phone layout).
- No background timers assumption: sync must tolerate being suspended and resuming
  (it already does — delta sync is stateless between runs).
- Realistic caveat: iOS build won't be free effort (App Store, background fetch
  limits, keyboard-first UX doesn't translate). Door open ≠ v1 requirement.

## Cross-device sync (multiple Macs, later iOS)

Still no server. Mail state already syncs through Gmail: read, archive, trash,
labels, pin (a `STARRED` flip). What does **not** is the app-local state, and it
is tiny — a few KB:

| State | Where it lives today | Sync? |
| --- | --- | --- |
| Reminders (`threads.scheduled_at`) | SQLite, per thread, per account | **yes** — the one that hurts |
| Prefs: hidden sidebar folders, account color, signature, AI provider + model | localStorage / SQLite | yes |
| OAuth refresh tokens, AI API key | OS keychain | **no** — each device logs in on its own; AI key pasted per device (or iCloud Keychain, below) |

### Decision: Google Drive `appDataFolder`, one per connected account

Drive's [application data folder](https://developers.google.com/workspace/drive/api/guides/appdata)
is a hidden, per-OAuth-client folder in the user's own Drive: invisible in the
Drive UI, readable only by our client ID, wiped by the user from Google account
settings. Free, plain REST from the Rust core (same `reqwest`, same tokens, same
per-account sync loop), works identically on macOS, iOS and any future desktop
target.

- **Scope**: add `https://www.googleapis.com/auth/drive.appdata` to the OAuth
  scope set (`crates/adapter-gmail/src/oauth.rs`). Existing users re-consent once.
  Setup doc gains one step: enable the Drive API in the GCP project. The folder
  is per OAuth client, so every device must use the same client ID — already true.
- **Per account, no "anchor" account**: reminders for account A's threads live in
  A's app data folder. Global prefs are written to *every* account's folder and
  merged on read. A device with a subset of accounts gets exactly the data it
  needs, and there is no "which account owns sync" question.
- **One file per device — no write races**: Drive v3 has no `If-Match`
  conditional update, so a single shared file would lose updates. Each device
  writes only its own `state-<device-id>.json`: a map of key → `{value, ts,
  device}`, tombstones included. Merge = newest `ts` per key across all files
  (state-based LWW map: idempotent, no journal, no compaction). Tombstones are
  garbage-collected after 30 days. Two devices at human speed never need more
  than LWW; no CRDT library.
- **Polling** piggybacks the per-account sync loop: `changes.list` with
  `spaces=appDataFolder` and a stored page token returns empty when idle; only
  changed files are downloaded (`files.get?alt=media`). Push after local
  mutations, debounced. Drive quota (325k units/min/user) is irrelevant at this
  volume.
- **Architecture**: a `SyncTransport` port in `core` with a Drive adapter; a
  `sync_state` table holds the page token and device id. Reminder writes stay
  optimistic (SQLite first, sync later) — same shape as the outbox.

### Rejected: Gmail as the metadata store

Gmail has no per-message custom properties. Hidden labels
(`labelListVisibility: labelHide`) work for booleans, but a reminder is a
timestamp — that means minting a label per date. Gmail's own snooze is not
settable via the API (`SNOOZED` is a system label). A JSON "config email" via
`messages.insert` under a hidden label works (Apple Notes over IMAP did this) but
shows up in All Mail and search, and every update is insert-then-delete. Drive's
app data folder is the same idea without the pollution.

### Later, optional: iCloud

Only for Apple-only users who want Google to hold nothing beyond mail, or for
syncing secrets. `tauri-plugin-icloud-kvs` exposes `NSUbiquitousKeyValueStore`
(1 MB, 1024 keys — enough) on macOS + iOS; costs an Apple developer account,
entitlements and a native plugin, and covers Apple devices only. Slot it as a
second `SyncTransport` adapter if it is ever asked for. For the AI key,
`apple-native-keyring-store` (`protected` feature) can mark keychain items
`kSecAttrSynchronizable` so iCloud Keychain moves it between devices without it
ever touching Drive.

## Security

An email client is a high-value target: it holds auth for your whole digital life and
renders untrusted HTML all day. Threat model + mitigations:

### Secrets

- OAuth refresh tokens + AI API keys live in the **OS keychain only** (`SecretStore`
  port) — never SQLite, never config files, never logs. Access tokens stay in memory.
- OAuth uses **PKCE** (code interception on the loopback redirect is useless without
  the verifier) + `state` parameter (CSRF). Loopback listener binds `127.0.0.1`,
  accepts exactly one request, and shuts down.
- Minimal scopes: `gmail.modify` in v1; `gmail.send` added only in M3. Never
  full `https://mail.google.com/` scope.
- Log hygiene rule: domain types implement `Debug` without bodies/addresses; token
  types redact themselves.

### Rendering untrusted mail (the big one)

- **Sanitize in Rust** with `ammonia` before HTML ever reaches the webview: strip
  scripts, event handlers, forms, iframes, external CSS.
- Render inside a **sandboxed iframe** (`sandbox` attr, no `allow-scripts`,
  `allow-same-origin` off) as defense-in-depth — sanitizer bugs shouldn't own the app.
- **Strict CSP** on the Tauri webview: no inline script, no eval, `connect-src` limited
  to the IPC bridge — mail content can't exfiltrate even if something slips through.
- **Remote images blocked by default** (tracking pixels), per-sender allow. When
  allowed, images are fetched by the Rust core (no cookies, no referrer), not by the
  webview.
- **Links**: click opens the system browser — never in-app navigation. Show the real
  URL on hover; flag mismatched link-text-vs-href (cheap phishing tell).
- Attachments: saved to disk with original name sanitized, never auto-opened, no
  preview execution.

### App surface

- **Tauri IPC allowlist**: only the typed commands the UI needs are exposed; no shell,
  no fs, no arbitrary-URL fetch capability granted to the frontend.
- Webview cannot reach the network except the IPC bridge (CSP above) — all Gmail/AI
  traffic goes through the Rust core.
- SQLite DB at rest: relies on OS disk encryption (FileVault) in v1. SQLCipher is a
  `Store`-adapter swap later if demanded. `ponytail:` accepted — the DB is a cache of
  data Google already holds; keychain holds the actual keys to the kingdom.
- AI: content leaves the machine only on explicit user action (see AI section);
  provider key scoped to that provider via the port boundary.

### Supply chain & distribution

- Cargo dependencies: small whitelist, `cargo audit` in CI, lockfile committed.
- Frontend: minimal npm surface (Svelte + a virtual-list), no analytics, no telemetry
  — ever. Easy promise for an open-source mail client; make it a headline feature.
- Release builds signed + notarized (macOS) once distribution starts (M4).

## Code architecture principles

Goal: every external dependency is **replaceable behind a trait**, every layer is
**upgradable in isolation**. Abstraction lives at the seams that realistically
change — not everywhere (an interface per struct is how codebases die).

### Ports & adapters (hexagonal-lite)

The core is pure domain logic; everything external enters through a port (trait):

```text
            ┌─────────────────────────────┐
  UI ──► │            core (domain)              │ ◄── tests (fake adapters)
         │  sync · triage · search · ai features │
         └───┬──────┬───────┬───────┬─────┘
     ports:  │      │       │       │
      MailProvider  Store  Keychain  AiProvider   (+ Clock, Notifier)
         │          │       │        │
     adapters:      │       │        │
      GmailApi   Sqlite  OsKeychain  OpenAi · (Anthropic · Ollama later)
```

Ports (traits) in v1 — and what each one future-proofs:

| Port | v1 adapter | Replaceable with |
| --- | --- | --- |
| `MailProvider` | Gmail REST | Outlook/Graph, JMAP, IMAP — someday |
| `Store` | SQLite/FTS5 | schema v2, different engine |
| `SecretStore` | OS keychain | iOS keychain, encrypted file fallback |
| `AiProvider` | OpenAI | Anthropic, Ollama, any OpenAI-compatible |
| `AuthFlow` | loopback redirect | iOS custom-URL-scheme redirect |
| `SyncTransport` | Drive `appDataFolder` | iCloud KVS, WebDAV, any blob store |

### Rules

- **Dependencies point inward.** Core depends on traits only; adapters depend on the
  core, never on each other. No `use gmail::*` outside the Gmail adapter — the core
  speaks its own domain types (`Thread`, `Message`, `Mutation`), adapters translate.
- **Workspace crates enforce the boundaries**: `core`, `adapter-gmail`,
  `adapter-sqlite`, `adapter-openai`, `app` (Tauri shell wires everything).
  The compiler polices the architecture — an adapter can't reach into another.
- **UI is a projection.** Svelte renders query results and fires commands; zero
  business logic in the frontend. UI framework is swappable by re-implementing views
  over the same IPC contract (typed command/event schema, versioned).
- **Versioned, migration-only schema** (sqlite migrations from day one). The DB is a
  cache: worst-case recovery is always "drop and re-sync from Gmail".
- **One trait, one responsibility.** New capability on a port = new method with a
  default impl, so existing adapters keep compiling.
- **Fakes over mocks**: each port ships an in-memory fake; core logic (sync
  state-machine, outbox, triage) is tested against fakes, no network in tests.
- **Errors are typed at ports** (`MailError::RateLimited`, `AuthError::Expired`) so
  the core's retry/re-auth policy is provider-agnostic.
- **No abstraction without a second use in sight.** The table above is the whitelist;
  anything else earns a trait only when a real second implementation shows up.

## Milestones

1. **M1 — feels instant**: 1 account. OAuth, 30-day backfill, thread list renders
   from SQLite, j/k/enter/esc, archive (optimistic + outbox). *Go/no-go gate: does
   it feel Superhuman-fast? If not, fix before adding anything.*
2. **M2 — daily-drivable reading**: account #2, unified inbox, delta sync loop,
   search (FTS5), mark read/unread, trash, command palette, dark mode.
3. **M3 — full switch**: compose/reply/forward (`gmail.send`), attachments view,
   notifications, remote-image blocking, **AI: BYO OpenAI key, summarize + draft
   reply + Ask AI**. Cancel Superhuman.
4. **M4+ (unordered)**: snooze (local), cross-device sync (Drive `appDataFolder`), split inbox, more AI providers
   (Anthropic, local/Ollama), AI triage experiments, shared OAuth client + release
   builds, iOS spike.

## Risks

- **Gmail API quotas**: generous for personal use (250 quota units/s/user); backfill
  uses batching + `format=metadata` to stay cheap. Low risk for 2 accounts.
- **OAuth verification** for a distributed app with `gmail.modify` = Google review +
  possible security assessment. v1 sidesteps via bring-your-own client ID.
- **HTML email rendering**: sanitization (XSS) and CSS chaos in a webview. Use a
  battle-tested sanitizer (ammonia in Rust) + sandboxed iframe; accept imperfect
  rendering of marketing mail.
- **Webview perf** on huge lists: virtualize the list from day one.
- **Tauri iOS maturity**: door-open strategy only; don't promise dates.

## Stack summary

| Piece | Choice |
| --- | --- |
| Shell | Tauri 2 |
| Core | Rust (reqwest, rusqlite/sqlx, ammonia, keyring) |
| DB | SQLite + FTS5 |
| UI | Svelte + TypeScript |
| Auth | OAuth 2 PKCE loopback, tokens in OS keychain |
| Mail API | Gmail REST v1 (users.threads / messages / history / labels) |
| AI | OpenAI API, BYO key in keychain, provider trait for future backends |
