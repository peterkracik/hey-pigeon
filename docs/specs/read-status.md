# Read status

Status: Approved — steps 1–4 merged (#142, #144, #147, #150), the relay deployed and `o.heypigeon.app` live; step 5 (send, poll, off switch) implemented, not merged; steps 6–7 not started
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
  recipient (To + Cc; a Bcc is not kept for stored mail and cannot be
  counted); the name is the one the thread shows for that address. With several recipients the line is "Opened <when>" and its
  detail says "by one of N recipients". `<when>` is the newest open, in
  the app's relative date format (`Formatters`).
- R6. The message view shows the status on the user's own messages, in the
  message's header. Under it, on an open message, are the events the app
  knows, newest first, when they say more than the status line does (more
  than one event, or a status that is a reply or a bounce): each open with
  its time, and "Delivered to a device that hides opens" for a hidden
  one; five at most, then "and N earlier". Nothing else about the reader is shown, because
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
  | `POST /v1/tokens` `{ token }` | Google access token, as `register-token` (tokeninfo + Gmail profile) | Stores `opens/{token} → { mailboxHash, createdAt, expiresAt, events: [] }`. `409` for a token that exists under another mailbox, expired or not (a token never changes hands). `429` when the mailbox already holds 20,000 live tokens. `503`, nothing stored, while the relay has no pixel domain. Answers `{ pixelUrl }`, always on the pixel's own domain, never the host the request came to. |
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

  `opened` and `hidden` record `{ label, at }` on the document and send
  the existing silent APNs push to the devices registered for that
  mailbox. A fetch with the same label within 60 seconds of that label's
  last event records nothing. Each label keeps at most 25 events: the
  first 24, and from then on always the latest (the newest replaces the
  25th). So one label can never crowd out the other, and "last opened"
  stays true however often a message is fetched. The source
  address and user agent are never stored, never logged and never sent to
  the app. If Apple's ranges could not be loaded, an instance labels by
  user agent alone and never guesses `opened` for a fetch it cannot tell
  from Apple's proxy. A downloaded list with a range wider than a /8
  (IPv4) or a /16 (IPv6) is not Apple's and counts as not loaded.

  On the three authenticated routes a failing store answers `503
  { error: "unavailable" }` and logs the error's code. Nothing printed on
  an `opens` instance, by this code or by the framework under it, carries
  a token, an address, a user agent, a URL or a request body.
- R22. `opens` documents expire 30 days after registration (Firestore TTL
  on `expiresAt`). After that a pixel is an unknown token. The app shows
  the last status it stored.
- R23. The app asks for opens (Query) only for accounts whose setting is
  on, only for tokens younger than 30 days, in the normal sync round —
  which is the Mac's 30-second timer, and on the phone the open,
  pull, background refresh and the silent push. Not every token every
  round: a token is asked about again at once in its first hour, then
  every 5 minutes for a day, every 30 minutes for a week, and every 3
  hours after that, at most 100 a round, longest unasked first. A round
  with no token due makes no request. A failed query changes
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
| Core (`desktop-app/crates/core`, adapters) | New `core::readstatus`: the status of a sent message as a pure function over the thread's messages and the stored events (R1–R5), bounce and reply detection (R3, R4), token creation, the flush rule (R16), pixel insertion and the HTML part made from plain text (R17), the poll (R23), the catch-up (R19), the off switch (R12, R13). `domain`: `Mutation::Send` gains `track_opens: bool` and `open_token: Option<String>` (both `serde(default)`, so rows queued by older builds still parse); `Account.read_status: bool`; `ReadStatus`, `OpenEvent`, `RecentOpen`. `ports`: three `MailProvider` methods with default "not supported" impls — register, query, delete — and the `Store` methods for the two tables; `fakes` gains both. `outbox::drain` calls the flush rule for a `Send`. `sanitize`: the own-pixel rule (R18), `own_pixel_token(raw_html)`, and the one definition of the pixel's URL shape (`OWN_PIXEL_PATH_PREFIX`, `OWN_PIXEL_SUFFIX`, `OWN_PIXEL_TOKEN_DIGITS`, `own_pixel_token_of_url`), which the sender of step 5 builds its URL from. `Message.open_token`: what the full fetch read, carried on the fetch's result; no store keeps it before the code that writes `open_tokens` (step 5; the table itself is migration v34, step 4). `devsync`: `ACCOUNT_FIELD_READ_STATUS`. `adapter-gmail`: new `opens.rs` beside `push.rs` (the three relay calls with the account's access token; the token never crosses the FFI), token extraction in `full_fetch` before `sanitize::html`, pixel appended in `build_mime`'s input. `adapter-sqlite`: migration v34 (below). |
| Bridge (`crates/ffi`, `RustEngine`, `MockEngine`) | `Engine.set_read_status(account_id, enabled)`; `Engine.configure_relay(relay_url)` (the shell hands over the baked URL at launch; kept under `relay.url`, apart from push's keys); `Engine.read_status_available()` (relay configured or not); `Engine.recent_opens(account_id?, limit)`; `MailMessage` gains `read_status` (state, newest time, events) → `MessageItem.readStatus`; `Mutation.Send.track_opens`; `Account.read_status`. Discovery of the opens URL and the poll run inside `sync_account`, next to `renew_watch`. `MockEngine`: the same operations, with one sent thread in each state so previews and tests show all five. |
| Shared shell (`ios-app/HeyPigeon`) | `AppModel.setReadStatus(_:for:)`, `AppModel.recentOpens`, `SendDraft.trackOpens` and its default (R15) as a static function; the status line in `MessageHeaderLine`; `Features/ReadStatus/RecentOpensView.swift` (the list, shared by all three); the "Read status" row and footer in `SettingsView`'s account editor; the composer's switch in `ComposeView`; the wording of R1 and R5 in one place (`ReadStatusText`, static, testable). |
| iPhone / iPad only | The "Recent Opens" row in `SidebarSheet` (iPhone) and the iPad sidebar (`Features/Pad`). `AppDelegate` needs no change: a push without `email` already syncs every account (`NewMailNotifier.handle`). |
| Mac only (`macos-app/HeyPigeonMac`) | Entry points only: "Recent Opens" in `SidebarColumn`, a palette entry, `g o` in `KeyboardMap.resolve` / `characters` / `ShortcutsSheet.groups`, all through `WindowState.run`. The Mac build gets the relay URL (`HEYPIGEON_RELAY_URL` in `publish-macos` and `macos-ci`) without the push entitlement. |
| Relay (`relay/`) | `index.js`: `functions.http("opens", …)`. New `src/opens-handlers.js`: the four routes, pure, with the `onOpen` seam for R24. New `src/opens.js` (Firestore `opens` collection), `src/classify.js` (pure: address + user agent + age → label), `src/ranges.js` (Apple's egress list, fetched once per instance, never bundled; unavailable → the classifier works from the user agent, where Apple's proxy is still `hidden`). `registerToken` gains `GET` and `opensUrl` ("Discovery of the opens URL", below). |
| Infrastructure (`terraform/`) | `functions.tf`: `google_cloudfunctions2_function.opens` (entry point `opens`, `ALLOW_ALL`, `allUsers` invoker, same source object, 512M, one CPU, 80 requests per instance, at most 3 instances), `OPENS_URL` in `register-token`'s environment (the custom domain, empty until mapped; an explicit `depends_on` orders the three functions so they do not race for the staging bucket), the domain mapping for `o.heypigeon.app` behind `opens_domain` (off by default). `logging.tf`: the `google_logging_project_exclusion` for the `opens` service's request logs, which the function and its invoker `depends_on`. `firestore.tf`: `google_firestore_field` with a TTL on `opens.expiresAt`. `outputs.tf`: `opens_url`, `opens_run_url`, `opens_domain_records`. `bootstrap/iam.tf`: the custom role `relayLogExclusions` for the deployer — the one part applied by hand. `deploy-relay.yml`: `workflow_dispatch` (plan or apply, `main` only). |

**SQLite, migration v34** (v32 and v33 were taken by other work before step 4):

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

As shipped in step 5 the wording differs from the first draft of this
table in three places, each to be literally true: the Settings footer
says "or that it reached a device that hides opens" and no longer "or on
what device" (the relay's `hidden` label is a fact about the device), and
ends with what turning it off does, the one delete included; the privacy
page says the app sends the relay a Google access token, and that the
records are deleted "as soon as that device is online"; the site and the
README headline is "No server for your mail", not "no server of any
kind". The files are the wording of record.

| Where | Today | Becomes |
| --- | --- | --- |
| `SettingsView`, new footer under the account's "Read status" row (all platforms; `ReadStatusSetting.footer`) | — | "Adds an invisible picture to mail you send from this account. When a recipient's mail app loads it, a small relay records that the message was opened and when, or that it reached a device that hides opens — never who or where, and never the message itself. The relay keeps this for 30 days. Recipients are not told and cannot agree to it first; in the EU and the UK that can require their consent, and it is yours to obtain. Apple Mail hides opens, and opening your own sent message in Gmail on the web counts as one. Turning this off deletes what the relay holds for this account as soon as the app is online; from then on nothing is added to your mail and the relay is not contacted for it." |
| Composer, the switch's help and VoiceOver label (all platforms) | — | "Read status" · "Read status is on for this message" / "Read status is off for this message" |
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
| Surface | Status and its events in the open message's header (thread view); composer sheet. Recent Opens (step 6): a list pushed from the sidebar sheet | Same views in the iPad layout | Status and its events in the open message's header (thread page); inline composer or window. Recent Opens (step 6): a list page |
| Entry points | The composer's footer: the eye button, "Read status", when the From account has it on. Step 6: sidebar sheet → "Recent Opens" | Same | The same eye button in the composer's footer. Step 6: sidebar → "Recent Opens"; `g o`; palette "Recent Opens" |
| Settings | Settings → Accounts → account → "Read status", off | same | same (Settings window) |
| How it learns of opens | Sync on open, pull, background refresh; silent push when "New mail (push)" is on | same | The 30-second sync |
| Status | Steps 1–5 implemented: every status in the header, the setting, the composer switch, tracked sends, the poll, the off switch. Recent Opens and the silent push on open not started | same | same |

## Platform differences

- **How fast an open appears.** The Mac polls every 30 seconds while it
  runs; the phone and iPad are told by a silent push when push is on, and
  otherwise at their next sync. Reason: the Mac build has no push
  entitlement (`macos-app/project.yml`), and iOS suspends the app. Same
  data, same query, different clock.
- **`g o` and the palette entries** exist on the Mac only (with a
  hardware keyboard the iPad uses the sidebar row). Platform idiom.
- Nothing else. Wording, defaults, precedence, the flush rule and the off
  switch are one implementation in the core and `AppModel`; the
  composer's switch and the Settings row are one view each, in the shared
  shell. There is no Mac-only entry point for the composer's switch (no
  key, no palette entry): the button is the same on all three.

## Acceptance criteria

Core (`cargo test`, against `MemStore` / `FakeProvider`):

- [x] R1, local half — `status_precedence_reply_beats_bounce_beats_sent`, `only_sent_mail_has_a_status`, `each_sent_message_is_judged_by_what_followed_it` (`core::readstatus`); at the bridge, `a_thread_carries_the_read_status_of_its_sent_mail` (`ffi`)
- [x] R1 — with opens: `status_precedence_reply_beats_bounce_beats_open_beats_hidden` (`core::readstatus`); at the bridge `a_thread_carries_opens_and_hidden_fetches` (`ffi::readstatus`)
- [x] R2 — `local_statuses_need_no_relay_and_no_setting` (step 1: the rule takes the thread's messages and nothing else; the "fake's opens calls count zero" half joins it in step 5, when there are such calls)
- [x] R3, R4 — `bounce_is_not_a_reply`, `reply_after_send_is_replied`
- [x] R11, R13 — `setting_off_makes_no_opens_request`: for an account with the setting off, a send the user asked to track, a sync round's poll and catch-up, and the same after "off" was learned through sync from another device make zero register, query and delete calls (`core::readstatus`); `a_provider_without_read_status_sends_untracked`
- [x] R12 — `turning_off_deletes_once_and_retries_until_sent`, `turning_on_again_cancels_a_pending_delete` (`core::readstatus`); `turning_off_here_asks_the_relay_to_forget_the_mailbox` (`ffi::readstatus`). R13's "no delete from a device that learned it" is in `setting_off_makes_no_opens_request`
- [x] R16 — `a_tracked_send_gets_its_token_when_it_is_queued`, `flush_tracks_only_when_choice_and_setting_and_relay`, `setting_off_before_flush_sends_untracked`, `failed_registration_sends_without_pixel` (network, refusal, rate limit, auth, and an answer that is not this message's pixel), `retry_reuses_token` (`core::readstatus`); the pixel's host — `the_pixel_is_on_the_relays_own_host_with_this_token` (`adapter-gmail::opens`)
- [x] R17, R18 — `pixel_is_last_in_html`, `plain_only_message_gets_html_part`, `draft_never_carries_pixel`, `a_quoted_pixel_is_never_sent_on` (`core::readstatus`); `outgoing_html_loses_own_pixels_and_only_those` (`sanitize.rs`)
- [x] R18 — `own_pixel_is_removed_without_marker`, `own_pixel_in_quoted_reply_is_removed`, `sanitize_stays_idempotent_with_own_pixel`, and that nothing changed for anyone else's pixel: `a_foreign_pixel_still_gets_the_marker` (`sanitize.rs`)
- [x] R19, the reader — `own_pixel_token_is_read_from_raw_html` (`sanitize.rs`), `token_is_read_from_raw_sent_html` (`adapter-gmail`)
- [x] R19 — `tokens_are_kept_from_fetched_sent_mail`, `catch_up_is_bounded` (`core::readstatus`); `sent_threads_without_bodies_are_recent_sent_and_unfetched`, `open_tokens_and_events_round_trip` (`adapter-sqlite`)
- [x] R23 — `poll_skips_off_accounts_and_expired_tokens` (a repeated answer inserts nothing), `poll_asks_by_age_and_in_batches` (`core::readstatus`); `a_query_answer_is_read_strictly` (`adapter-gmail::opens`)
- [x] Migration — `v34_upgrade_adds_read_status_off_and_empty_tables`, `removing_account_removes_tokens_and_events` (`adapter-sqlite`)
- [x] R9, R13 (the setting follows; no delete yet) — `read_status_setting_syncs_as_account_field` (`devsync`)
- [x] R8, R10, R25 at the bridge — `read_status_is_off_by_default_and_needs_a_relay`, `the_switch_is_per_account_and_recorded_for_other_devices`, `a_changed_relay_forgets_the_old_ones_answer`; R11 for discovery — `the_relay_is_asked_only_for_an_account_with_read_status_on`, `discovery_does_nothing_while_read_status_is_off` (`ffi::readstatus`); the relay's answer — `relay_info_reads_the_opens_url_or_its_absence` (`adapter-gmail`)

Relay (`node --test`, no network):

- [x] R20 — `opens.test.js`: register needs a valid Google token; unknown token → GIF, one lookup and nothing else; known token → GIF, one append, one `onOpen`; query returns only the caller's tokens; delete is `204` twice in a row. `register-token.test.js`: `GET` answers `{ topic, opensUrl }` and writes nothing
- [x] R21 — `classify.test.js`: Gmail proxy, direct client, Apple range, Apple's list unavailable, grace window, scanner, `HEAD`; `ranges.test.js`: parsing, lookup, one fetch per instance, failure and retry; the event rule in `opens.test.js` (`a repeat within a minute…`, `one label cannot fill a token…`, `the event rule on its own`)
- [x] R20 — a token never changes hands after expiry; the per-mailbox cap answers 429; no `pixelUrl` without a pixel domain; a failing store answers 503 with a code in the log (`opens.test.js`, `register-token.test.js`)
- [x] R21 — a damaged or over-wide range file is a failed load (`ranges.test.js`); what a library prints on the instance is reduced to a class name (`quiet.test.js`, and the reproduction in `relay/README.md`)
- [x] R20, R21 — no handler test can find an IP or user agent in what the store, the push or the log received (`no address, user agent or URL reaches the store, the notification or the log`)

Shell (Swift Testing over `MockEngine`, `ios-app/HeyPigeonTests`):

- [x] R1, local half — `eachStateHasItsWords`, `theMockFollowsTheCoresRule`, `aMockThreadShowsWhatBecameOfSentMail` (`ModelTests`, `ReadStatusTests`) — green in `ios-ci` and `macos-ci` on #142
- [ ] R1, R5, R6 — `openedAndHiddenHaveTheirWords`, `detailsListWhatTheRelayReported`, `theMockRanksOpensLikeTheCore`, `aTranscriptCarriesNoPictureAddress` (`ModelTests`) — written, not yet compiled: ticked when `ios-ci` and `macos-ci` are green
- [ ] R15, R16 — `trackOpensDefaultsOnOnlyWhenTheAccountsSettingIsOn`, `changingFromReevaluatesTrackOpens`, `aScheduledMessageKeepsTheChoiceMadeWhenItWasSent`, `theReadStatusRowSaysWhatItDoes` (`AppModelTests`) — written, not yet compiled
- [ ] R7 — `recentOpensAreNewestFirstAndRespectTheAccountFilter`
- [x] R8, R10 — `readStatusIsOffByDefaultAndDisabledWithoutARelay`, `pushIsOfferedOnlyWhereTheAppCanBePushedTo` (`AppModelTests`) — green in `ios-ci` and `macos-ci` on #150 (`theReadStatusRowIsNotShownYet`, green there too, is replaced in step 5 by `theReadStatusRowSaysWhatItDoes`)

Mac (`macos-app/HeyPigeonMacTests`):

- [ ] `g o` resolves to Recent Opens; the palette, `KeyboardMap.characters` and `ShortcutsSheet.groups` agree (`MacWindowTests`)

Whole feature:

- [ ] Same wording and symbol on every platform (strings of R1 and "Read status" are found once, in the shared shell: `ReadStatusText`, `ReadStatusSetting`; "Recent Opens" is step 6)
- [ ] `MockEngine` covers the new operations
- [ ] `rust-ci`, `ios-ci`, `macos-ci`, `deploy-relay` green
- [ ] Every row of "Privacy copy" changed in the same PR that makes it necessary; reviewed by `security-privacy`
- [ ] `terraform plan` shows a `$0` shape: no load balancer, no minimum instances; the log exclusion is confirmed in the console after the first pixel request
- [ ] Measured on the deployed function: cold-start time and memory with Apple's ranges loaded (a synthetic 300,000-line list parsed at about 237 MB locally, so 256M is out and 512M stays unless the real number says otherwise)
- [ ] Checked on the deployed project: Cloud Trace spans of `opens` carry no URL or user agent (the log exclusion does not cover Trace); the real shape of `X-Forwarded-For` on the run.app URL and on the domain mapping (the handler takes the last entry); no other log sink or log-based metric receives the service's request log; `FUNCTION_TARGET` or `K_SERVICE` is `opens` on the instance, so the quiet console is installed

## Suggested order (each step merges on its own)

1. **Local statuses.** `core::readstatus` for Sent / Not delivered /
   Replied, the bridge field, `MockEngine`, the status line in
   `MessageHeaderLine` on all three platforms. No relay, no setting, no
   privacy change. Ships value alone.
2. **Own-pixel rule in the sanitizer** (R18) and token extraction (R19's
   reader). Inert until something sends a pixel; must be in every
   installed build before step 5 so no device ever loads one.
3. **Relay and infrastructure.** `opens` function, classifier, tests;
   Terraform (function, TTL, `OPENS_URL`, `GET` on `register-token`, the
   log exclusion the function depends on, the domain mapping behind a
   variable). By hand, once, before the merge: a bootstrap apply that
   lets the deployer manage log exclusions. Nothing calls it yet.
4. **Store and setting.** Migration v34, `Account.read_status`, the
   devsync field, `set_read_status`, the Settings row — built, and kept
   out of Settings (`ReadStatusSetting.isShown`) until step 5, because a
   switch that does nothing is worse than none — the Mac build's relay
   URL, the Mac's OAuth client accepted by the relay. Still sends no
   pixel and makes no call to `opens`.
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
- The Terraform for read status is applied by the `deploy-relay` Action,
  not from a laptop. The request-log exclusion is in the root stack and
  the `opens` function depends on it, so the function cannot exist
  without it. The one laptop step is a bootstrap apply granting the
  deployer a custom role for log exclusions (`relayLogExclusions`), since
  CI never holds project IAM. Accepted cost: the CI identity can then
  create, change or delete any log exclusion of the project.
- The domain mapping is created by the same Action once `OPENS_DOMAIN` is
  set, after the deployer service account is made a verified owner of
  `heypigeon.app` in Search Console and the CNAME exists. Until then the
  function answers at its run.app URL but `register-token` reports no
  `opensUrl`, so the apps have no read status and no pixel carries a
  run.app address.
- Apple's egress ranges are fetched by the function at cold start, not
  bundled. If they cannot be loaded, the fetch is labelled by user agent:
  Apple's proxy stays `hidden`, and only a fetch that names a mail client
  or browser is `opened`.
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
3. **Grace window of 2 minutes; 25 events per label and token, repeats
   within 60 seconds dropped; 100 tokens per query; 20,000 live tokens
   per mailbox** (Gmail's 500 recipients a day for 30 days is 15,000).
   Numbers to tune after real traffic.
4. **Catch-up (R19)** fetches bodies of the user's own recent sent mail.
   A cheaper variant is a custom header on the outgoing message (the
   metadata tier could read it without a body fetch); not chosen because
   the decision was "from the message's own HTML".
5. **Bounce detection is by sender name only** (R3). A bounce from an
   unusual address is treated as a reply.
6. **`g o`** for Recent Opens on the Mac (free in `KeyboardMap.chord`
   today).

Still open — needs the owner or a measurement:

- **Memory for `opens`**: set to 512M, twice the other two, for Apple's
  egress ranges. Unmeasured; the acceptance measurement decides whether
  256M is enough.
- **OAuth clients the relay accepts**: `google_client_ids` holds the iOS
  client only, and the Mac app signs in with its own (`GoogleMacClientID`).
  Until the Mac's client id is added, `register-token` and `opens` refuse
  the Mac's tokens — to settle in step 4, with the Mac build's relay URL.
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

Step 1, 2026-11-19 — **Verified with notes**. Merged as #142.

- `rust-ci`, `ios-ci` and `macos-ci` were green on the merged head; the
  Swift compiled and `ReadStatusTests` passed. (One Mac test from #141,
  `aMessageOpenedInPlaceInTheListCanBeSelected`, failed once and passed
  on a re-run of the same commit; cause not established, looked at
  separately.)
- Note: the status line has not been seen on a device.
- Step 1 shows the status on an open message of the thread only (not on
  a folded one, not in the composer's history), and has no event list
  (R6): there are no events before step 5.
- Known and left as it is: `core::sync::settle_follow_ups` still counts
  a bounce as a reply, so a bounce ends a "remind me if no reply"
  follow-up while read status says "Not delivered".

Step 2, 2026-11-19 — **Verified with notes**. Merged as #144.

- Rust only; no Swift, bridge, schema, relay, setting or copy changed.
  `rust-ci`, `ios-ci` and `macos-ci` were green on it.
- Inert: nothing writes a pixel, and `Message.open_token` is read by
  nothing yet.
- The pixel is known by its path shape on any host (R18), not by
  `o.heypigeon.app` alone: the relay is self-hostable.
- Not covered: a pixel reached other than through an `<img>` (a CSS
  background) — the app never writes one that way.

Step 3, 2026-11-19 — **Verified with notes**. Merged as #147 and deployed.
Reworked after the security review of #147.

- `npm ci && npm test` in `relay/`: 64 tests pass. `terraform fmt -check
  -recursive` and `terraform validate` (root and bootstrap, 1.9.8,
  `-backend=false`) pass.
- The framework's pre-handler logging (a pixel path with a broken escape,
  a malformed JSON body) was reproduced locally with `functions-framework
  --target=opens` and is gone with `src/quiet.js` installed: stderr shows
  the error's class name and nothing of the request.
- Not run, and not runnable without the project: `terraform apply`.
  Whether the custom role is enough for the exclusion, whether the
  deployer may set the TTL policy, the domain mapping, and that the
  request log is really gone after the first pixel request are
  unverified until it is deployed.
- To check on the deployed project (listed under the acceptance
  criteria): Cloud Trace, the shape of `X-Forwarded-For`, other sinks and
  log-based metrics, measured memory, and that the instance recognises
  itself as `opens`.
- The default CPU and concurrency of a function this size (a fraction of
  a CPU, one request at a time) is from memory of Google's documentation,
  not read off the project; the values are now set explicitly either way.
- The classifier's signals (Gmail's proxy name, the bare `Mozilla/5.0` of
  Apple's proxy, the shape of Apple's list) are from memory of how those
  services behave, tested against fixtures, not against live traffic.
- A manual workflow run is held to `main` by the `infra` environment's
  deployment-branch rule in the repository settings, which this repository
  cannot check; the step in the workflow is only a guard against a slip.
- Nothing in the apps or the core calls the function; no privacy copy in
  the apps or the site changed. `README.md`, `CLAUDE.md`, `DESIGN.md`,
  `relay/README.md` and `terraform/README.md` describe what is deployed
  after the merge.

Step 3 on the deployed project, 2026-11-19:

- `terraform apply` on merge: 5 added, 2 changed, 1 destroyed. The custom
  role, the TTL policy and the CPU and concurrency settings were accepted.
- From outside: the pixel with an unknown token answers 200 `image/gif`,
  42 bytes; `register-token` `GET` without a token 401; the `opens` query
  without a token 401.
- #149: `deploy-relay` reads `OPENS_DOMAIN` as a variable or a secret. Its
  apply created the `o.heypigeon.app` mapping, and `register-token` now
  reports `opensUrl = https://o.heypigeon.app`.
- Still unchecked there: that the request-log exclusion really keeps the
  `opens` request log out of storage; Cloud Trace spans; the shape of
  `X-Forwarded-For`; that the instance recognises itself as `opens` (the
  quiet console); measured memory; and the domain's certificate, which
  was still pending when last looked at.

Step 4, 2026-11-19 — **Verified with notes**. Merged as #150; `rust-ci`, `ios-ci` (iPhone tests, iPad build), `macos-ci` and the relay checks were green on it, so the Swift compiled and the three new `AppModelTests` passed on both platforms.

- Rust: `cargo fmt --all -- --check`, the `cargo test` line of `rust-ci`
  and its Swift bindgen step pass locally. `terraform fmt -check
  -recursive` and `validate` pass for both stacks.
- Swift (`Models`, `RustEngine`, `MockEngine`, `AppModel`,
  `PushController`, `Platform`, `SettingsView`, `AppModelTests`) was
  written on Linux and has never been compiled: `ios-ci` and `macos-ci`
  are its first build.
- The Settings row exists and is not shown (`ReadStatusSetting.isShown`
  is false) on any platform; no privacy copy changed. Step 5 shows it,
  with its footer, when a build can send.
- R12 for now: turning the setting off writes and syncs it and sends
  nothing to the relay. No build has ever registered a token, so there
  is nothing of the mailbox there to delete; the delete, its retry and
  the `opens.delete_pending` marker come with the code that registers
  (step 5).
- The only relay request this step can make is the write-free `GET` on
  `register-token`, once a day, for an account with read status on — and
  with the row hidden no account can be turned on from the app.
- Not verifiable here: that `HEYPIGEON_RELAY_URL` exists on the `macos`
  environment and `HEYPIGEON_MAC_OAUTH_CLIENT_ID` on `infra` (without
  them the Mac build has no relay and the relay does not learn the Mac's
  client — both are the state before this step); the discovery call
  against the real relay; the Mac build with a relay URL showing no push
  switch.

The deployed relay since: `https://o.heypigeon.app` is live with a
certificate (an unknown-token pixel answers 200 `image/gif`, 42 bytes;
`POST /v1/opens` without a token 401), and `register-token` reports
`opensUrl = https://o.heypigeon.app`. `HEYPIGEON_MAC_OAUTH_CLIENT_ID` was
added for the `infra` environment; that the apply put it into
`GOOGLE_CLIENT_IDS` is not yet confirmed. `HEYPIGEON_RELAY_URL` on the
`macos` environment is not confirmed.

Step 5, 2026-11-19 — **Verified with notes**. Not merged.

- Rust: `cargo fmt --all -- --check`, the `cargo test` line of `rust-ci`
  and its Swift bindgen step pass locally. Relay tests pass (a comment
  changed in `handlers.js`, nothing else).
- Swift (`Models`, `RustEngine`, `MockEngine`, `AppModel`,
  `ScheduledSends`, `ComposeView`, `MessageHeaderLine`, `SettingsView`,
  `ModelTests`, `AppModelTests`) was written on Linux and has never been
  compiled: `ios-ci` and `macos-ci` are its first build.
- No mail was sent and the live relay was not called from here. What
  only a real send to a real mailbox shows, and is therefore unverified:
  that Gmail keeps the `<img>` in a sent message's HTML as written, so
  the token is read back from it; that Gmail's image proxy, Apple Mail
  and other clients fetch it as the classifier expects; that the relay
  accepts the app's access token (and the Mac's client); the 2-minute
  grace window against a real first open; the catch-up on a second
  device; the delete on switching off; how the status and its events
  look in the thread.
- Decided in this step and recorded above: the poll's schedule (R23);
  the event list shown inline rather than on a tap (R6); "one recipient"
  counted over To and Cc (R5); the composer's switch as a button in the
  footer on every platform, with no Mac key or palette entry; turning the
  setting on again before a pending delete went out cancels the delete;
  a scheduled message from a file an older build wrote goes untracked.
- A message sent by Siri, a Shortcut or as an invitation's answer from an
  account with read status on is tracked like any other: the setting is
  the account's, and there is no composer to switch it off in.
- Known and left: `README.md` says push is "off by default" while a build
  with a relay starts with it on (`PushController`); not this feature's
  sentence. `core::sync::settle_follow_ups` still counts a bounce as a
  reply.

Steps 6–7: not started.
