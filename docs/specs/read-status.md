# Read status

Status: Approved — step 1 (local statuses) implemented, not merged; steps 2–7 not started
Related: `relay/README.md`, `terraform/README.md`, `DESIGN.md`
("Push notifications", "Rendering untrusted mail", "Cross-device sync",
"Optimistic mutations"), `docs/specs/reply-recipients.md`

## What and why

"Did they get it, did they read it?" for mail I sent, the way Superhuman
shows it: each message I send says whether it was sent, bounced, opened or
answered, and a "Recent Opens" list shows what was opened lately. Bounces
and replies are read from the mailbox itself. An open can only be seen by
a server, so that one part goes through the relay — and is therefore a
switch, per mailbox, off until I turn it on.

**Out of scope:**

- Link-click tracking.
- Disguising the pixel to get past blockers (no misleading file names, no
  rotating hosts, no CSS tricks). A recipient who blocks remote images is
  simply never "Opened".
- Per-recipient copies of a message. One message carries one pixel; with
  several recipients the app knows that someone opened, not who.
- A notification or banner when a message is opened. The status and the
  Recent Opens list are the whole surface.
- Mail sent from another client (Gmail web, Apple Mail): it has no pixel.
  It still gets the local statuses (R2).
- The Tauri shell and `prototype/`.

## Behaviour

### The statuses

- R1. Every message the user sent (label `SENT`, from the account's
  address or one of its aliases) has exactly one status, shown in these
  words on every platform:

  | Status | Shown as | Source |
  | --- | --- | --- |
  | Sent | "Sent" | Gmail accepted the message. Local. |
  | Not delivered | "Not delivered" | A bounce in the thread (R3). Local. |
  | Hidden | "Delivered · opens hidden" | The pixel was fetched by Apple's mail privacy proxy (R17). Relay. |
  | Opened | "Opened <when>" / "Opened by <name> <when>" | The pixel was fetched by a mail client or Gmail's image proxy. Relay. |
  | Replied | "Replied <when>" | A reply in the thread (R4). Local. |

  Precedence, highest first: Replied, Not delivered, Opened, Hidden, Sent.
  A reply implies the message was read and overrides everything else.
  "Hidden" is its own state and is never shown or counted as opened.
- R2. Sent, Not delivered and Replied are computed on the device from the
  stored thread. They work with the setting off, without a relay, offline,
  and for mail sent from any client.
- R3. A bounce is a message in the same thread, newer than the sent
  message, not `SENT` and not `DRAFT`, whose From local part is
  `mailer-daemon` or `postmaster` (any letter case). It is read from the
  headers the list tier already stores; no body is fetched for it.
- R4. A reply is a message in the same thread, newer than the sent
  message, not `SENT`, not `DRAFT` and not a bounce (R3).
- R5. "Opened by <name>" is used when the message had exactly one
  recipient (To + Cc + Bcc); the name is the one the thread shows for that
  address. With several recipients the line is "Opened <when>" and its
  detail says "by one of N recipients". `<when>` is the newest open, in
  the app's relative date format (`Formatters`).
- R6. The message view shows the status on the user's own messages, in the
  message's header. Opening it lists the events the app knows, newest
  first: each open with its time, and "Delivered to a device that hides
  opens" for a hidden one. Nothing else about the reader is shown, because
  nothing else is known (R18).
- R7. "Recent Opens" is a list of the user's messages with at least one
  open, newest open first: recipients, subject, "Opened <when>". It is a
  query over the local store, across all accounts (or the account the app
  is filtered to), and holds nothing the relay did not already report.
  Choosing a row opens the thread. Empty state: "No opens yet", and when
  no account has the setting on, one line that says read status is off and
  where to turn it on.

### The setting

- R8. Read status is a setting of each mailbox: Settings → Accounts →
  the account → "Read status". Off by default for every account, existing
  and new. It is independent of "New mail (push)".
- R9. The setting syncs to the user's other devices through the existing
  Drive app-data sync, as the account's name, colour and signature do
  (`account:read_status` on that account's own file, newest write wins).
- R10. The setting needs a relay. In a build without a relay URL
  (`HeyPigeonRelayURL` empty) the row is shown disabled with "Not
  available in this build", and a value of "on" arriving through sync
  changes nothing on that device: it adds no pixel and asks no relay.
- R11. While the setting is off for an account, for that account: no pixel
  is added to outgoing mail, no token is registered, and the app makes no
  request of any kind to the opens endpoint. Statuses already stored stay
  visible; they stop changing.
- R12. Turning the setting off on a device does three things, in this
  order: the setting is written (and synced); polling for that account
  stops; the relay is asked to delete every live token of that mailbox
  (R16, Delete). Pixels already sent then name unknown tokens and record
  nothing. If the delete cannot be sent (offline), it is retried on the
  following sync rounds until it succeeds, and it is the only request the
  account makes to the opens endpoint while off.
- R13. A device that learns through sync that the setting was turned off
  elsewhere stops adding pixels and stops polling at once, and sends no
  delete of its own: the device that flipped the switch owns it. The
  delete is idempotent, so a second one (two devices switched off in the
  same minute, a retry after a lost answer) is harmless.
- R14. Turning the setting on again starts fresh: new messages are
  tracked; messages sent before stay at the status they had.
- R15. The composer has a per-message switch, "Read status", shown only
  when the sending account's setting is on (and a relay exists); it starts
  on. Changing the From account re-evaluates it. Off sends that one
  message with no pixel and no token.

### Sending

- R16. What decides whether a message is tracked is the state at the
  moment it leaves the outbox, not when Send was pressed:
  - The queued send carries the composer's choice (R15) and a random
    128-bit token, made when it is queued.
  - At flush, if the choice is on **and** the account's setting is still
    on **and** a relay is configured, the token is registered with the
    relay and only then the pixel is added and the message sent. This
    covers the Undo window, "Send later", a send queued offline, and a
    setting changed on another device meanwhile.
  - If the setting was turned off (here or elsewhere) before the flush,
    the message goes out with no pixel and nothing is registered.
  - If the setting was off when Send was pressed and is turned on before
    the flush, the message is not tracked: the user never saw the switch
    for it.
  - If registration fails for any reason (relay down, timeout, 4xx/5xx),
    the message goes out on time without a pixel. Mail is never delayed
    or parked because of the relay. Its status is the local one.
  - A retried send (Gmail refused or the network dropped after
    registration) reuses the same token.
- R17. The pixel is one `<img>` at the end of the HTML part:
  `https://<pixel host>/o/<32 hex>.gif`, `width="1" height="1" alt=""`.
  A message with no HTML part gets one made from its plain text (escaped,
  line breaks kept), so the pixel has somewhere to live; the plain part is
  unchanged. Drafts saved to Gmail never contain a pixel.
- R18. The app never loads its own pixel. The sanitizer removes any
  `<img>` whose URL path has the shape `/o/<32 hex>.gif`, whatever the
  host, and leaves no tracker marker in its place — so the user's own Sent
  mail and a reply that quotes it do not say "1 tracking picture blocked",
  and "Load remote images" cannot fetch it. Quoted text in a new reply or
  forward is built from the sanitized body, so an old pixel is never sent
  out again.
- R19. Every device learns a message's token from the message itself: the
  raw HTML of the user's own sent message is read for the pixel before it
  is sanitized, and the token is stored against that message. No token is
  written to the Drive sync map. Because bodies are fetched lazily, a
  device fetches the body of the user's own sent messages from the last
  30 days that it has not read yet, a few per sync round, while the
  account's setting is on.

### The relay

- R20. One new Cloud Run function, `opens`, in the same code bundle and
  under the same `relay-fn` service account. Its routes:

  | Route | Auth | Does |
  | --- | --- | --- |
  | `POST /v1/tokens` `{ token }` | Google access token, as `register-token` (tokeninfo + Gmail profile) | Stores `opens/{token} → { mailboxHash, createdAt, expiresAt, events: [] }`. Refuses a token that exists under another mailbox. Answers `{ pixelUrl }`. |
  | `GET /o/<token>.gif` | none (public) | Always answers a valid 1×1 GIF at once: `200`, `image/gif`, `Cache-Control: no-store, no-cache, must-revalidate, private`, no redirect, no cookie. Unknown, expired or malformed token: the GIF and nothing else — no read beyond the lookup, no write, no push, no log line. Known token: R21. |
  | `POST /v1/opens` `{ tokens: [...] }` (at most 100) | Google access token | Answers `{ <token>: [{ label, at }] }` for the tokens that belong to the caller's mailbox; other tokens are left out without saying why. |
  | `DELETE /v1/tokens` | Google access token | Deletes every `opens` document of the caller's mailbox. `204` whether or not there were any. |

  A token is in the HTML every recipient receives, so holding one proves
  nothing: Query and Delete are bound to the mailbox, never to the token.
- R21. A fetch of a known token is classified in memory, from the source
  address and user agent of that request, into one label:

  | Fetch | Label | Shown as |
  | --- | --- | --- |
  | Gmail's image proxy | `opened` | Opened |
  | A mail client or browser, directly | `opened` | Opened |
  | Apple's mail privacy proxy (source address inside Apple's published egress ranges, loaded at cold start) | `hidden` | Delivered · opens hidden |
  | Anything within the grace window after `createdAt` (2 minutes), or scanner-like (security gateways, link checkers, a `HEAD`) | ignored | nothing stored |

  `opened` and `hidden` append `{ label, at }` to the document (at most 50
  events per token; later ones are dropped) and send the existing silent
  APNs push to the devices registered for that mailbox. The source
  address and user agent are never stored, never logged and never sent to
  the app. If Apple's ranges could not be loaded, an instance labels by
  user agent alone and never guesses `opened` for a fetch it cannot tell
  from Apple's proxy.
- R22. `opens` documents expire 30 days after registration (Firestore TTL
  on `expiresAt`). After that a pixel is an unknown token. The app shows
  the last status it stored.
- R23. The app asks for opens (Query) only for accounts whose setting is
  on, only for tokens younger than 30 days, in the normal sync round —
  which is the Mac's 30-second timer, and on the phone the open,
  pull, background refresh and the silent push. A failed query changes
  nothing and is not reported to the user; the next round asks again.
- R24. The silent push for an open carries no address and no token:
  `{ aps: { content-available: 1 }, opens: 1 }`. The device runs its
  ordinary sync round. It is only sent to devices that registered for
  "New mail (push)"; with push off the phone learns of opens at its next
  sync.

### Edge cases

- R25. Two accounts: each has its own setting, tokens and events; a
  message is tracked by the setting of the account it is sent from.
- R26. Removing an account from a device deletes its local tokens and
  events and sends nothing to the relay (other devices may still use the
  mailbox; the documents expire on their own).
- R27. Known limitation, stated in the setting's footer: opening the
  message in Gmail on the web, in the Sent folder, loads the pixel through
  Gmail's image proxy and counts as an open. The same holds for any other
  mail client the user reads their own Sent mail in.
- R28. A message whose recipients include the user's own address shows
  its status like any other; an open may be the user's own (R27).
- R29. A large mailbox costs nothing extra: statuses are derived per open
  thread, the token table holds only tracked messages, and R19's catch-up
  is bounded to 30 days and a few threads per round.

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core (`desktop-app/crates/core`, adapters) | New `core::readstatus`: the status of a sent message as a pure function over the thread's messages and the stored events (R1–R5), bounce and reply detection (R3, R4), token creation, the flush rule (R16), pixel insertion and the HTML part made from plain text (R17), the poll (R23), the catch-up (R19), the off switch (R12, R13). `domain`: `Mutation::Send` gains `track_opens: bool` and `open_token: Option<String>` (both `serde(default)`, so rows queued by older builds still parse); `Account.read_status: bool`; `ReadStatus`, `OpenEvent`, `RecentOpen`. `ports`: three `MailProvider` methods with default "not supported" impls — register, query, delete — and the `Store` methods for the two tables; `fakes` gains both. `outbox::drain` calls the flush rule for a `Send`. `sanitize`: the own-pixel rule (R18) and `own_pixel_token(raw_html)`. `devsync`: `ACCOUNT_FIELD_READ_STATUS`. `adapter-gmail`: new `opens.rs` beside `push.rs` (the three relay calls with the account's access token; the token never crosses the FFI), token extraction in `full_fetch` before `sanitize::html`, pixel appended in `build_mime`'s input. `adapter-sqlite`: migration v32 (below). |
| Bridge (`crates/ffi`, `RustEngine`, `MockEngine`) | `Engine.set_read_status(account_id, enabled)`; `Engine.read_status_availability()` (relay configured or not); `Engine.recent_opens(account_id?, limit)`; `MailMessage` gains `read_status` (state, newest time, events) → `MessageItem.readStatus`; `Mutation.Send.track_opens`; `Account.read_status`. Discovery of the opens URL and the poll run inside `sync_account`, next to `renew_watch`. `MockEngine`: the same operations, with one sent thread in each state so previews and tests show all five. |
| Shared shell (`ios-app/HeyPigeon`) | `AppModel.setReadStatus(_:for:)`, `AppModel.recentOpens`, `SendDraft.trackOpens` and its default (R15) as a static function; the status line in `MessageHeaderLine`; `Features/ReadStatus/RecentOpensView.swift` (the list, shared by all three); the "Read status" row and footer in `SettingsView`'s account editor; the composer's switch in `ComposeView`; the wording of R1 and R5 in one place (`ReadStatusText`, static, testable). |
| iPhone / iPad only | The "Recent Opens" row in `SidebarSheet` (iPhone) and the iPad sidebar (`Features/Pad`). `AppDelegate` needs no change: a push without `email` already syncs every account (`NewMailNotifier.handle`). |
| Mac only (`macos-app/HeyPigeonMac`) | Entry points only: "Recent Opens" in `SidebarColumn`, a palette entry, `g o` in `KeyboardMap.resolve` / `characters` / `ShortcutsSheet.groups`, all through `WindowState.run`. The Mac build gets the relay URL (`HEYPIGEON_RELAY_URL` in `publish-macos` and `macos-ci`) without the push entitlement. |
| Relay (`relay/`) | `index.js`: `functions.http("opens", …)`. `src/handlers.js`: the four routes, pure. New `src/opens.js` (Firestore `opens` collection), `src/classify.js` (pure: address + user agent + age → label), `src/ranges.js` (Apple's egress list, loaded once per instance). `registerToken` gains `GET` and `opensUrl` ("Discovery of the opens URL", below). |
| Infrastructure (`terraform/`) | `functions.tf`: `google_cloudfunctions2_function.opens` (entry point `opens`, `ALLOW_ALL`, `allUsers` invoker, same source object, `depends_on` the other two so the three do not race for the staging bucket), `OPENS_URL` in `register-token`'s environment, the domain mapping for `o.heypigeon.app`. `firestore.tf`: `google_firestore_field` with a TTL on `opens.expiresAt`. `outputs.tf`: `opens_url`. `bootstrap/`: a `google_logging_project_exclusion` for the `opens` service's request logs (new `logging.tf`), applied by hand from a laptop like the rest of bootstrap. |

**SQLite, migration v32** (the next free number; v31 is the newest today):

```sql
ALTER TABLE accounts ADD COLUMN read_status INTEGER NOT NULL DEFAULT 0;

CREATE TABLE open_tokens (
    token       TEXT PRIMARY KEY,           -- 32 hex
    account_id  TEXT NOT NULL,
    message_id  TEXT,                       -- NULL until the sent message is seen (R19)
    thread_id   TEXT,
    sent_at     INTEGER NOT NULL,           -- epoch ms
    expires_at  INTEGER NOT NULL,           -- sent_at + 30 days: no poll after it
    polled_at   INTEGER
);
CREATE INDEX open_tokens_account ON open_tokens(account_id, expires_at);
CREATE INDEX open_tokens_message ON open_tokens(message_id);

CREATE TABLE open_events (
    token  TEXT NOT NULL,
    at     INTEGER NOT NULL,                -- epoch ms, the relay's clock
    label  TEXT NOT NULL,                   -- 'opened' | 'hidden'
    PRIMARY KEY (token, at, label)          -- a repeated poll inserts nothing
);
CREATE INDEX open_events_recent ON open_events(label, at DESC);
```

Both tables are deleted with their account, as the other per-account
tables are. A pending off-switch delete (R12) is a `sync_meta` key
(`opens.delete_pending`), so it needs no schema. The opens URL and pixel
URL the relay reported are kept the way `push.rs` keeps the topic
(SecretStore key/value: `opens.url`, `opens.pixel_url`), separate from the
push keys, because "New mail (push)" off clears those.

**Discovery of the opens URL.** The app keeps one relay setting, the
baked `HeyPigeonRelayURL`. `register-token` reports `opensUrl` beside
`topic`. It also gains an authenticated `GET` that answers the same
`{ topic, opensUrl }` and writes nothing, because the Mac has no APNs
device token to register and a phone with push off must not register one
just to find the URL. The app calls it only when some account has the
setting on.

Syncs between devices: the per-account setting only
(`account:read_status`, last writer wins). Tokens and events do not sync:
every device reads tokens from the sent mail (R19) and events from the
relay (R23).

Leaves the device — only for an account with the setting on:

- To the relay: the Google access token (as today for push), and a random
  token per tracked message. Not the message, its subject, its recipients
  or its id.
- To the recipients: one remote image URL inside the message.
- The relay stores, per tracked message, `sha256(mailbox address)`, the
  token, and for each counted fetch a label and a time, for 30 days. It
  sees each fetching client's IP address and user agent for the length of
  the request and keeps neither.

### Privacy copy — every sentence that changes

The copy is conditional on the setting: the "no server" sentences must
hold for a user who never turns it on, and must not claim more than that.

| Where | Today | Becomes |
| --- | --- | --- |
| `SettingsView`, new footer under the account's "Read status" row (all platforms) | — | "Adds an invisible picture to mail you send from this account. When a recipient's mail app loads it, a small relay records that the message was opened and when — never who, where, or on what device, and never the message itself. The relay keeps this for 30 days. Recipients are not told and cannot agree to it first; in the EU and the UK that can require their consent, and it is yours to obtain. Apple Mail hides opens, and opening your own sent message in Gmail on the web counts as one. Off: nothing is added and the relay is not contacted for this account." |
| `SettingsView`, text under the row when unavailable | — | "Not available in this build" |
| `NotificationsSection.footer`, iPhone / iPad | "Goes through a small relay that only ever sees your address and a change counter, never mail; …" | "Goes through a small relay that for new mail only ever sees your address and a change counter, never mail; …" (the rest unchanged) |
| `NotificationsSection.footer`, Mac | "…composes the banner itself; nothing goes through a relay." | "…composes the banner itself; new mail never goes through a relay." |
| `SettingsView`, "Load remote images" description | unchanged | unchanged — still true; R18 keeps the app's own pixel out of it |
| `site/privacy.html`, opening paragraph | "…runs entirely on your device and has no backend server. Nobody but you — not even the developer — can see your email, contacts, or account data through Hey Pigeon." | "…runs on your device and talks directly to your Google account. It has two optional features that use a small relay server, described below; neither ever receives your email. Nobody but you — not even the developer — can see your email, contacts, or account data through Hey Pigeon." |
| `site/privacy.html`, "Where your data lives" | "It is never transmitted to any server operated by the developer, because no such server exists." | "It is never transmitted to any server operated by the developer. The relay described below never receives mail." |
| `site/privacy.html`, new section "The relay (optional)" after "Where your data lives" | — | "Push notifications on iPhone and iPad go through a relay that sees your email address and a change counter and stores a one-way hash of the address with your device's push token. Read status is off unless you turn it on for an account. When it is on, each message you send from that account contains an invisible image, and the relay stores a random identifier for that message, a one-way hash of your address, and the time of each open, for 30 days. It sees the IP address and mail app of whoever loads the image while answering the request and does not store or log them. Turning read status off deletes those records. Tracking opens can require the recipient's consent under EU and UK law; you are responsible for that when you turn it on." |
| `site/privacy.html`, "No selling, no ads, no analytics" | "…does not run any tracking or analytics." | "…does not run any analytics and does not track you. Read status, if you turn it on, tells you when mail you sent was opened (see above)." |
| `site/privacy.html`, "Revoking access & deleting data" | "Since all data is local, uninstalling the app…removes everything Hey Pigeon has stored." | "Since your mail is stored only on your device, uninstalling the app…removes it. Relay records are deleted when you turn off push or read status, and expire on their own (read status after 30 days)." |
| `site/privacy.html`, "Last updated" | 2026-09-17 | the date of the change |
| `site/index.html`, "No backend. Ever." and the "No server, ever" card | "Hey Pigeon has no server of any kind." / "Client-only." | "Your mail never touches a server of ours." with one sentence naming the two optional relay features; card title "No server for your mail". |
| `README.md`, "No backend, ever" | "has **no server component of any kind**" … "The one honest exception: iOS push…" | Headline claim narrowed to mail content; "The one honest exception" becomes two: push, and read status (opt-in per account; a token and open times, never mail). |
| `relay/README.md` | Title "(optional, iOS only)"; "What the relay sees and stores"; "Turning it off" | Title drops "iOS only"; a second table for `opens` (stored: token, mailbox hash, labels and times, 30 days; seen per fetch and not kept: IP, user agent; logged: nothing per pixel request); "Turning it off" gains the read status switch. |
| `handlers.js` privacy contract comment, `DESIGN.md` "Push notifications" tier 3 and iOS section, `docs/ios.md` (push row, "any server beyond…"), `.claude/agents/security-privacy.md` rule 4, `CLAUDE.md` (root, "sees an address and a change counter, never mail"), `macos-app/README.md` and `macos-app/CLAUDE.md` ("the relay is the phone's"), `terraform/README.md` (functions, cost, manual steps), `terraform/outputs.tf` description ("Paste this into the iOS app…" is already untrue: the URL is baked) | "sees an address and a change counter, never mail" and its variants | Each gains the read-status half: "…and, for accounts with read status on, a random token per sent message and when it was opened. Never mail." |

App Store privacy answers and `PrivacyInfo.xcprivacy` need a look by the
`security-privacy` agent before release: the app itself collects nothing
new about its user, but the declaration must still be literally true.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Surface | Status in the message header (thread view); Recent Opens as a list pushed from the sidebar sheet; composer sheet | Same views in the iPad layout; Recent Opens in the sidebar column | Status in the message header (thread page); Recent Opens as a list page; inline composer or window |
| Entry points | Tap the status for its events; sidebar sheet → "Recent Opens"; composer's ••• → "Read status" | Same; sidebar → "Recent Opens" | Click the status; sidebar → "Recent Opens"; `g o`; palette "Recent Opens"; composer's ••• → "Read status"; palette "Read status for this message" while composing |
| Settings | Settings → Accounts → account → "Read status", off | same | same (Settings window) |
| How it learns of opens | Sync on open, pull, background refresh; silent push when "New mail (push)" is on | same | The 30-second sync |
| Status | Step 1 implemented (Sent / Not delivered / Replied in the open message's header); the rest not started | same | same |

## Platform differences

- **How fast an open appears.** The Mac polls every 30 seconds while it
  runs; the phone and iPad are told by a silent push when push is on, and
  otherwise at their next sync. Reason: the Mac build has no push
  entitlement (`macos-app/project.yml`), and iOS suspends the app. Same
  data, same query, different clock.
- **`g o` and the palette entries** exist on the Mac only (with a
  hardware keyboard the iPad uses the sidebar row). Platform idiom.
- Nothing else. Wording, defaults, precedence, the flush rule and the off
  switch are one implementation in the core and `AppModel`.

## Acceptance criteria

Core (`cargo test`, against `MemStore` / `FakeProvider`):

- [x] R1, local half — `status_precedence_reply_beats_bounce_beats_sent`, `only_sent_mail_has_a_status`, `each_sent_message_is_judged_by_what_followed_it` (`core::readstatus`); at the bridge, `a_thread_carries_the_read_status_of_its_sent_mail` (`ffi`)
- [ ] R1, R5 — with opens (step 5): `status_precedence_reply_beats_bounce_beats_open_beats_hidden`
- [x] R2 — `local_statuses_need_no_relay_and_no_setting` (step 1: the rule takes the thread's messages and nothing else; the "fake's opens calls count zero" half joins it in step 5, when there are such calls)
- [x] R3, R4 — `bounce_is_not_a_reply`, `reply_after_send_is_replied`
- [ ] R11 — `setting_off_makes_no_opens_request` (register, query, delete all zero over a send and a sync round)
- [ ] R12, R13 — `turning_off_deletes_once_and_retries_until_sent`, `off_learned_from_sync_stops_without_delete`
- [ ] R16 — `flush_tracks_only_when_choice_and_setting_and_relay`, `setting_off_before_flush_sends_untracked`, `failed_registration_sends_without_pixel`, `retry_reuses_token`
- [ ] R17 — `pixel_is_last_in_html`, `plain_only_message_gets_html_part`, `draft_never_carries_pixel`
- [ ] R18 — `own_pixel_is_removed_without_marker`, `own_pixel_in_quoted_reply_is_removed`, `sanitize_stays_idempotent_with_own_pixel` (`sanitize.rs`)
- [ ] R19 — `token_is_read_from_raw_sent_html` (`adapter-gmail`), `catch_up_is_bounded`
- [ ] R23 — `poll_skips_off_accounts_and_expired_tokens`, `repeated_poll_inserts_nothing`
- [ ] Migration — `v32_upgrade_adds_read_status_off_and_empty_tables`, `removing_account_removes_tokens_and_events` (`adapter-sqlite`)
- [ ] R9 — `read_status_setting_syncs_as_account_field` (`devsync`)

Relay (`node --test`, no network):

- [ ] R20 — `opens.test.js`: register needs a valid Google token; unknown token → GIF and zero store calls; known token → GIF, one append, one push; query returns only the caller's tokens; delete is `204` twice in a row
- [ ] R21 — `classify.test.js`: Gmail proxy, direct client, Apple range, grace window, scanner, `HEAD`; the event cap
- [ ] R20, R21 — no handler test can find an IP or user agent in what the store, the push or the log received

Shell (Swift Testing over `MockEngine`, `ios-app/HeyPigeonTests`):

- [ ] R1, local half — `eachStateHasItsWords`, `theMockFollowsTheCoresRule`, `aMockThreadShowsWhatBecameOfSentMail` (`ModelTests`, `ReadStatusTests`) — written, not yet compiled: ticked when `ios-ci` and `macos-ci` are green
- [ ] R1, R5, R6 — with opens (step 5): `ReadStatusText` wording for Opened and Hidden, one and several recipients (`ModelTests`)
- [ ] R15 — `trackOpensDefaultsOnOnlyWhenTheAccountsSettingIsOn`, `changingFromReevaluatesTrackOpens` (`AppModelTests`)
- [ ] R7 — `recentOpensAreNewestFirstAndRespectTheAccountFilter`
- [ ] R8, R10 — `readStatusIsOffByDefaultAndDisabledWithoutARelay`

Mac (`macos-app/HeyPigeonMacTests`):

- [ ] `g o` resolves to Recent Opens; the palette, `KeyboardMap.characters` and `ShortcutsSheet.groups` agree (`MacWindowTests`)

Whole feature:

- [ ] Same wording and symbol on every platform (strings of R1, "Recent Opens", "Read status" found once, in the shared shell)
- [ ] `MockEngine` covers the new operations
- [ ] `rust-ci`, `ios-ci`, `macos-ci`, `deploy-relay` green
- [ ] Every row of "Privacy copy" changed in the same PR that makes it necessary; reviewed by `security-privacy`
- [ ] `terraform plan` shows a `$0` shape: no load balancer, no minimum instances; the log exclusion is confirmed in the console after the first pixel request
- [ ] Measured on the deployed function: cold-start time and memory with Apple's ranges loaded (decides 256M or 512M)

## Suggested order (each step merges on its own)

1. **Local statuses.** `core::readstatus` for Sent / Not delivered /
   Replied, the bridge field, `MockEngine`, the status line in
   `MessageHeaderLine` on all three platforms. No relay, no setting, no
   privacy change. Ships value alone.
2. **Own-pixel rule in the sanitizer** (R18) and token extraction (R19's
   reader). Inert until something sends a pixel; must be in every
   installed build before step 5 so no device ever loads one.
3. **Relay and infrastructure.** `opens` function, classifier, tests;
   Terraform (function, TTL, `OPENS_URL`, `GET` on `register-token`);
   bootstrap log exclusion applied by hand **before** the function is
   public; the domain mapping. Nothing calls it yet.
4. **Store and setting.** Migration v32, `Account.read_status`, the
   devsync field, `set_read_status`, the Settings row (disabled or off
   everywhere), the Mac build's relay URL. Still sends no pixel.
5. **Send, poll, off switch.** The flush rule, pixel, registration, the
   poll in `sync_account`, catch-up, delete on off; the composer switch;
   Opened / Hidden in the header. All privacy copy lands in this PR.
6. **Recent Opens.** The shared list and each platform's entry points
   (`g o`, palette, sidebar rows).
7. **Silent push on open** (R24), last: the feature is complete without
   it, it only makes the phone faster.

## Decisions (made with the owner; recorded, not open)

- Three visible delivery states, not two: Apple's privacy proxy is
  "Delivered · opens hidden", never "Opened".
- One message, one pixel; no per-recipient copies.
- Off by default, opt-in, **per account**, synced through the Drive
  app-data sync; independent of the push toggle; needs a relay.
- A per-message switch in the composer when the account's setting is on.
- Off means no pixel, no token, no request; the switching device asks the
  relay to delete the mailbox's tokens; the delete is idempotent.
- One new function `opens` with register, pixel, query and delete; labels
  computed in flight; IP and user agent never stored; 30-day TTL.
- Tokens are recovered from the sent mail, not synced through Drive.
- The app never loads its own pixel. Gmail web's Sent folder counting as
  an open is a known limitation.
- **Pixel host: `o.heypigeon.app`, a Cloud Run domain mapping** (free: one
  DNS record and a domain verification; the feature is "preview" at
  Google). Alternatives considered and rejected: the raw `run.app` URL
  (ties every sent message to a URL that changes if the service is ever
  recreated); a load balancer (about $18 a month, breaks "$0 at personal
  volume"); Cloudflare Workers (would split the relay across two
  providers while push and the device tokens stay in Google Cloud).
- The request-log exclusion lives in `terraform/bootstrap/` and is applied
  by hand.
- Cost stays $0 at personal volume.
- Link-click tracking and blocker evasion are out.
- **Not delivered outranks Opened** when one of several recipients
  bounced and another opened (R1). Showing both was the alternative.
- **A failed relay registration sends the message on time, untracked**
  (R16). Sending the pixel and registering later would lose the opens in
  between.
- **A tracked plain-text message gets an HTML part** generated from its
  text (R17), rather than plain-text sends never being tracked.
- **No notification when a message is opened.** The status and the Recent
  Opens list are the whole surface.

## Open questions / assumptions

Assumed, following how the app already behaves — say no to any of them:

1. **Wording**: "Delivered · opens hidden" for the third state; "Opened
   by one of N recipients" for several recipients; "Read status" as the
   name of both the setting and the composer switch.
2. **The token is made at queue time and lives in the outbox row**, so a
   retry reuses it. It is registered only at flush.
3. **Grace window of 2 minutes, 50 events per token, 100 tokens per
   query.** Numbers to tune after real traffic.
4. **Catch-up (R19)** fetches bodies of the user's own recent sent mail.
   A cheaper variant is a custom header on the outgoing message (the
   metadata tier could read it without a body fetch); not chosen because
   the decision was "from the message's own HTML".
5. **Bounce detection is by sender name only** (R3). A bounce from an
   unusual address is treated as a reply.
6. **`g o`** for Recent Opens on the Mac (free in `KeyboardMap.chord`
   today).

Still open — needs the owner or a measurement:

- **Memory for `opens`**: 256M like the other two, or 512M for Apple's
  egress ranges. Unmeasured; decided by the acceptance measurement.
- **Domain verification for the mapping**: the mapping is created by the
  CI deployer (`relay-deployer`, which has `roles/run.admin`), and Google
  requires the identity creating it to be a verified owner of
  `heypigeon.app`. Either that service account is added as an owner in
  Search Console (a manual prerequisite for `terraform/README.md`) or the
  mapping is created by hand once and imported.
- **EU ePrivacy / UK PECR.** Reading that a mail was opened is access to
  information on the recipient's device and, for recipients in the EU and
  the UK, generally needs their prior consent (ePrivacy Directive
  Art. 5(3); the EDPB's 2023 guidelines on its technical scope name email
  tracking pixels). The app cannot collect that consent — the user is the
  sender and the one responsible. The spec answers this with opt-in, the
  footer sentence and the privacy page; whether that is enough for a
  build distributed to other people (TestFlight) is the owner's call, not
  an engineering one.
- **App Store review** of a mail client that tracks opens: no known rule
  against it, not checked against current guidelines.

## Verification

Step 1, 2026-11-19 — **Verified with notes** (Rust only).

- Rust: `cargo fmt --all -- --check`, the `cargo test` line of
  `rust-ci` and its Swift bindgen step pass locally.
- Swift (`Models`, `RustEngine`, `MockEngine`, `MessageHeaderLine`,
  `ModelTests`) was written on Linux and has never been compiled:
  `ios-ci` and `macos-ci` have not run. Nothing seen on a device.
- Step 1 shows the status on an open message of the thread only (not on
  a folded one, not in the composer's history), and has no event list
  (R6): there are no events before step 5.
- Known and left as it is: `core::sync::settle_follow_ups` still counts
  a bounce as a reply, so a bounce ends a "remind me if no reply"
  follow-up while read status says "Not delivered".

Steps 2–7: not started.
