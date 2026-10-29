# Hey Pigeon for iOS — Siri, App Intents and on-device AI

Companion to [ios.md](./ios.md), whose iOS-M3 milestone lists "widgets,
Shortcuts actions, share extension" in one line. This document is that line
expanded into a plan, and it adds the two things iOS 26/27 make possible on
top of it: the new Siri reaching into the app, and Apple's on-device model
as the app's default AI. The principles do not move: **no backend, local
first, all logic in the Rust core, the UI is a projection** — and now, the
Siri/Shortcuts surface is a second projection of the same core.

> **Sources.** The App Intents and Foundation Models APIs this plan relies on
> for iOS 26 are documented. What it says about iOS 27 (SiriKit deprecated,
> App Intents as the only Siri route, personal context and on-screen
> awareness fed by app entities and the Spotlight index, multi-turn and
> long-running intents, Foundation Models with image input, Private Cloud
> Compute and a pluggable model provider) comes from WWDC26 coverage, not
> from Apple's reference. Every step below says what to verify before it
> starts. Nothing in this document has been compiled yet: the Swift side of
> the app has not been built on a Mac.

## Decision: App Intents in the app process, over `AppModel`

**Every Siri, Shortcuts, Spotlight, widget and Control entry point is an
`AppIntent` that runs inside the app process and calls the same `AppModel`
methods the swipes call. No App Intents extension in the first two steps.**

```text
 Siri · Shortcuts · Spotlight · Action button · Watch · Widgets · Controls
                                  │
                        ┌─────────▼──────────┐
                        │  HeyPigeon/Intents │   AppIntent · AppEntity · AppShortcutsProvider
                        └─────────┬──────────┘
                                  │  the same calls the gestures make
                        ┌─────────▼──────────┐
                        │      AppModel      │   markDone · remind · toggleNeedsReply · …
                        └─────────┬──────────┘
                                  │
                        ┌─────────▼──────────┐
                        │ RustEngine ◄─UniFFI│   crates/ffi → core · adapter-gmail · adapter-sqlite
                        └────────────────────┘
```

Why in-process:

- **The data is where the app is.** The SQLite store sits in the app's
  Application Support directory and the OAuth tokens in the app's Keychain
  items. An extension is a second process that cannot see either until both
  move into an App Group. In-process intents need no migration.
- **iOS launches the app for them.** Since iOS 16 an intent without
  `openAppWhenRun` runs in the app, in the background, with the app launched
  if it is not running. `HeyPigeonApp.init` already builds the engine with no
  UI involved, so that launch is cheap and correct.
- **One code path.** Optimistic update, outbox, undo semantics and the
  reminder rescheduling all live in `AppModel`. An intent that re-implemented
  "mark done" against the engine would drift from the swipe the moment
  either changed.

The cost is latency on a cold launch (the Rust engine opens SQLite before
the first intent can run — well under a second today) and that widgets,
which *must* run out of process, see data only through what the app leaves
for them. Step 6 handles widgets with a snapshot file in an App Group, and
the App Group migration of the database is deferred to the point where
something actually needs it.

### What runs where

| Caller | Process | Needs |
| --- | --- | --- |
| Siri, Shortcuts, Spotlight actions, Action button, Apple Watch | app, background | nothing new |
| Compose / Reply / Open intents | app, foreground (`openAppWhenRun`) | the existing deep-link path (`AppModel.openThread`, `composeDraft`) |
| Spotlight index of threads | app, after every sync | `CoreSpotlight` via `IndexedEntity` |
| Widgets, Live Activities, Controls that read data | widget extension | App Group with a small JSON snapshot |
| Interactive widget buttons | widget extension → app | the intents above, marked for in-app execution |

## Entities

Two `AppEntity` types, both thin copies of models the app already has.
Entities carry **only what the system needs to name and disambiguate**;
bodies never leave the engine.

```swift
struct MailThreadEntity: AppEntity, IndexedEntity {
    let id: String                   // ThreadRow.id
    @Property var subject: String
    @Property var from: String       // ThreadRow.fromSummary
    @Property var snippet: String    // one line, as the row shows it
    @Property var receivedAt: Date   // lastMessageAt
    @Property var account: MailAccountEntity
    @Property var isUnread: Bool
    @Property var isPinned: Bool
    @Property var needsReply: Bool
    @Property var reminderAt: Date?
    @Property var isDone: Bool
    // displayRepresentation: title = subject, subtitle = "from · when",
    // image = the account-coloured initial (Theme), like the row.
}

struct MailAccountEntity: AppEntity {
    let id: String                   // MailAccount.id (the address)
    @Property var email: String
    @Property var name: String       // displayName
}
```

Queries:

- `MailThreadQuery: EntityStringQuery` — `entities(for ids:)` through
  `engine.threadRow(id:)`; `entities(matching:)` through `engine.search`,
  which already runs FTS over sender, subject and body; `suggestedEntities()`
  returns the inbox's first page (the rows a user is most likely to mean).
- `MailAccountQuery: EntityStringQuery` with `suggestedEntities()` = all accounts and `entities(matching:)` over name and address. Every entity a Mail-schema intent takes as a parameter (account, mailbox, draft, message) needs a string query or `IndexedEntity`; the App Intents metadata extractor rejects the intent otherwise (the first archive said so).

The `UniqueEntity`-style singletons (`InboxEntity`, …) are not needed:
folders are an `AppEnum` (see Open below).

### Indexing (what the new Siri sees)

`MailThreadEntity` conforms to `IndexedEntity`, and the index is rebuilt in
the same place `ReminderScheduler.reschedule` runs: at the end of
`AppModel.sync()` and after a reminder is set. Rules:

- Index the latest 500 threads of each account from `engine.threads(in:
  .all …)` — inbox, Scheduled, Need reply and done mail alike (done mail is
  still mail Siri should know about). Not the whole archive: Spotlight
  indexing is per-item work on the main thread's launch budget, and the
  point is "what Siri should know about", not search (the app's FTS is
  better at search).
- Attributes: subject as title, sender as `authorNames`, snippet as
  `contentDescription`, `receivedAt`, account as `containerIdentifier`.
  **No body text**, no addresses other than the sender's display name.
- A thread in Trash or Spam is removed from the index (`delete entities
  with ids`) on the sync that sees it; removing an account drops the whole
  index and rebuilds it from the accounts left.
- **Settings › Siri & Search › "Let Siri see your inbox"** (default on for
  new installs; a pref, synced like the others). Off drains the index. The
  rationale is the one in the sources note: with iOS 27 Siri may hand entity
  text to a cloud model to reason about it. The index itself is on-device and
  inside the app's data protection class; the toggle exists for the step
  after that, which Apple controls, not us.

## Intents

One intent per verb, in the desktop's words. All of them take a
`MailThreadEntity` (Siri resolves "this", "the one from Anna", or asks),
all run in the background except where noted, and all end with the toast
text the swipe shows, returned as the Siri dialog.

| Intent | Calls | Parameters | Dialog |
| --- | --- | --- | --- |
| `MarkDoneIntent` | `markDone` / `markNotDone` | thread | "Marked done" |
| `RemindMeIntent` | `remind(at:onlyIfNoReply:)` | thread, when (preset or *Pick a date…*, **asked if missing**), date, onlyIfNoReply (default false) | "Reminder set for Tuesday 09:00" |
| `NeedReplyIntent` | `toggleNeedsReply` → explicit `set` | thread, on/off | "Marked Need reply" |
| `PinIntent` | `togglePin` → explicit `set` | thread, on/off | "Pinned" |
| `MarkReadIntent` | `markRead` / `toggleRead` → explicit `set` | thread, read/unread | — |
| `DeleteThreadIntent` | `delete` | thread | "Deleted" (`isDiscardable`, confirmation on) |
| `AddLabelIntent` | `setLabel` | thread, `MailLabelEntity` (same account) | "Label added · Travel" |
| `OpenThreadIntent` | `openThread(id:)` | thread | opens the app |
| `OpenFolderIntent` | `view = …`, `tab = …` | `Folder: AppEnum` (Inbox · Scheduled · Need reply · Starred · Drafts · Sent · Archive · All · Spam · Trash) | opens the app |
| `SearchMailIntent` | `engine.search` | text | returns `[MailThreadEntity]`, snippet list in Siri |
| `WhatNeedsReplyIntent` | `engine.threads(in: .needReply …)` | — | "3 threads need a reply" + the list |
| `WhatsDueIntent` | `scheduledThreads` filtered to due | — | "2 reminders are due" + the list |
| `ComposeIntent` | `composeDraft = SendDraft(to:subject:body:)` | to, subject, body (all optional) | opens the composer, nothing sent |
| `ReplyIntent` | `openReply(to:all:body:)` — `SendDraft.reply`, the thread view's own draft | thread, body (optional), replyAll | opens the composer on the reply |
| `SummarizeInboxIntent` | `summarize(group)` over today's active rows | account (optional) | the summary text; snippet view with "Open" |
| `SyncNowIntent` | `sync()` | — | "Up to date" |

Rules that come straight from the app's existing behaviour:

- **Nothing sends mail from an intent.** `ComposeIntent` and `ReplyIntent`
  open the composer; the 5-second send undo, the outbox and the
  deferred-commit rules stay the only way out. Siri "send an email" through
  the Mail schema (step 3) is the one exception, and there the schema's own
  confirmation step is the undo window.
- **Toggles become explicit sets** (`on: Bool`) so a Shortcut is
  idempotent; the swipe keeps toggling.
- The `RowAction` enum is the source of truth for which verbs exist. The
  Settings "Swipe actions" picker and the intents enumerate the same cases;
  a new verb lands in both or in neither.
- Intents are `@MainActor` and reach `AppModel.current` (the static the
  `AppDelegate` already uses). They never touch `RustEngine` directly.
- `SummarizeInboxIntent` is only offered when `aiConfigured` is true (step 5
  makes it true by default on Apple Intelligence devices).

### App Shortcuts (zero-setup phrases)

`AppShortcutsProvider` with the verbs a user would say with the app closed.
Phrases use the app name; the other words come from the app's vocabulary.

```text
"What needs a reply in Hey Pigeon"        → WhatNeedsReplyIntent
"What's due in Hey Pigeon"                → WhatsDueIntent
"Summarize my inbox in Hey Pigeon"        → SummarizeInboxIntent
"Search Hey Pigeon for ${text}"           → SearchMailIntent
"Compose in Hey Pigeon"                   → ComposeIntent
"Open Scheduled in Hey Pigeon"            → OpenFolderIntent(.scheduled)
"Check Hey Pigeon"                        → SyncNowIntent
```

Thread-bound verbs (Done, Remind, Need reply, Pin) are not App Shortcuts:
without a thread in hand they only make sense through on-screen awareness
(step 4), in Shortcuts flows after `SearchMailIntent`, or from a widget.

### Controls and the Action button

`ControlWidget` buttons for `ComposeIntent`, `OpenFolderIntent(.scheduled)`
and `SyncNowIntent` land in Control Center, the Lock Screen and the Action
button list for free once the intents exist. They live in the widget
extension (step 6) but need no data: they only fire intents.

## Step 3 — the Mail app schema domain

Apple ships a `.mail` App Intent domain (iOS 18+): entity schemas for
`message`, `draft`, `mailbox` and `account` (and `thread`, iOS 27 only),
and twelve intent schemas in three **use-case groups** — composing
(`createDraft` · `updateDraft` · `saveDraft` · `sendDraft`), replying (+
`replyMail`) and forwarding (+ `forwardMail`) — plus the standalone
`openMessage`, `openDraft`, `archiveMail`, `deleteMail`, `deleteDraft` and
`updateMail`. (The iOS 26 SDK has no `openMessage` / `openDraft` members
yet, so those two are plain `OpenIntent`s over the schema entities; the
name `DeleteIntent` is taken by the AppIntents protocol the `deleteMail` /
`deleteDraft` schemas conform to, hence `DeleteThreadIntent` in step 1.) Conforming (`@AppEntity(schema: .mail.message)`,
`@AppIntent(schema: .mail.replyMail)`) makes the new Siri understand "reply
to Anna's email saying I'll be late" with **no custom phrase**, because the
system already knows what a mail app does. Xcode warns for every schema
missing from a group the app partially adopts; all three groups are
complete here (`Intents/MailSchema.swift`, `Intents/MailSchemaIntents.swift`).

Decisions:

- **Thread vs message.** The schema is message-shaped; the app is
  thread-shaped. A `MailMessageEntity` is **the thread's latest message**,
  with the thread id as its id. It is built from the row alone (sender,
  subject, when, read, flagged = pinned, junk, mailbox from the Gmail
  labels, no network), and opening, archiving, replying to and forwarding
  it is exactly what the thread does. Its `body` is never filled in; the
  schema allows that, and bodies stay in the engine.
- **No new engine surface.** The plan expected `crates/ffi` to grow
  `message(id)`; the latest-message mapping made that unnecessary.
- **`MailThreadEntity`** was a plain entity while the app targeted iOS 26;
  it adopts `.mail.thread` now (see "iOS 27" below).
- **`category` is left out** of the message entity. The schema lists it as
  an optional `MailCategory?` whose enum schema (`.mail.category`) Apple
  documents without cases; if Xcode insists on it, add an `@AppEnum(schema:
  .mail.category)` with the generated cases.
- **Drafts.** A `MailDraftEntity`'s id is the draft's key: the open
  composer's `SendDraft.draftKey`, or a saved Gmail draft's message id. The
  composer now mirrors its live content into `AppModel.composeDraft` on
  every edit and adopts changes made from outside through
  `externalRevision`, so Siri's `updateDraft` reaches the screen and
  `sendDraft` sends what is on it.
- **`sendDraft` is the one send from Siri.** It goes through the same
  5-second undo as the Send button (`AppModel.sendComposeDraft`), only for
  a draft that is open or saved, never without a recipient; `sendLaterDate`
  is declined (no scheduled send in this app). The composer-opening
  intents (`createDraft`, `replyMail`, `forwardMail`) open the app and send
  nothing.
- **`updateMail`'s mailbox** maps onto the app's words: Inbox = not done,
  Archive = done, Trash = delete, Spam = the SPAM label; any other folder is
  declined with a spoken reason.

Verify on the first Xcode build: that the `@AppEntity(schema:)` macro
accepts the entities' extra initialisers and the `@AppIntent(schema:)`
macro accepts `openAppWhenRun` and the `ReturnsValue` results used here,
and whether the domain needs an entitlement or App Store distribution (the
app ships through TestFlight only).

## Step 4 — on-screen awareness and conversation

Two small additions make "Hey Siri, remind me about this tomorrow" work on
the open thread:

- `ThreadView` publishes the entity it shows: `.userActivity` with the
  thread's `EntityIdentifier` (`appEntityIdentifier`) so the system knows
  what "this" is. `MailListScreen` publishes the folder entity the same way
  for "summarize this".
- `RemindMeIntent` takes a required `When` enum — the Remind sheet's
  presets (*Later today*, *Tomorrow*, *This weekend*, *Next week*, *In a
  month*) plus *Pick a date…*, which asks for a `Date` with `requestValue`.
  A required enum is what makes Siri ask with the list when it was not
  said ("When?" — "Tomorrow"). iOS 27's multi-turn intents reportedly make
  that follow-up conversational; on iOS 26 it is the same API, shown as a
  picker. The preset maths live in `Shared/ReminderPresets.swift`, shared
  with the sheet, so both land on the same minute.

Long-running work (a full `sync()` on a cold engine, `SummarizeInbox` over
a slow provider) adopts the iOS 27 long-running / streaming intent protocol
if it holds, with a progress dialog; on iOS 26 it stays a plain await under
the 30-second background budget, same as `BGAppRefreshTask`.

## Step 5 — Foundation Models as the zero-key default

Today AI is bring-your-own OpenAI key. Apple's on-device model turns that
into **AI with no key, no account and no network** on an Apple Intelligence
device, which is a stronger version of this app's privacy thesis than BYO.
OpenAI stays as the opt-in upgrade.

### Where it plugs in

`core::ports::AiProvider` is a Rust trait and Foundation Models is a Swift
framework, so the adapter is **Swift code the Rust core calls back into**,
through a UniFFI foreign trait exactly like `EngineListener`
(`crates/ffi/src/ai.rs`, `ios-app/HeyPigeon/AI/AppleIntelligenceProvider.swift`):

```text
core  ──AiProvider──►  ffi::ForeignAiProvider  ──UniFFI with_foreign──►  Swift AppleIntelligenceProvider
                                                                          └─ LanguageModelSession
```

- `crates/ffi` has `AiBackend`, a `#[uniffi::export(with_foreign)]` trait:
  `id`, `models`, `complete(system, user) async` and
  `classify(subject, snippet, from, labels) async → TriageVerdict`. A
  `ForeignAiProvider` implements `core::AiProvider` over it. Feature code
  keeps calling `AiProvider::complete`; it never learns which side of the
  bridge answered.
- `Engine.open` is unchanged (the CI grep pins its signature); the shell
  calls `set_ai_backend` right after it when
  `SystemLanguageModel.default.availability == .available`, else nothing.
  `ai_status()` says which provider answers and what the device has, so
  Settings › AI shows "On this iPhone (Apple Intelligence) · answering"
  above the OpenAI row.
- **Provider selection is a pref** (`ai.provider`: `apple` | `openai`),
  synced like the others; unset means "on device when this device can,
  else the key". The engine resolves the **active** provider as the
  preferred one when it can answer, else the other one when it can: a
  device without Apple Intelligence keeps working off its key, a device
  without a key off its model. The desktop reads the same pref and ignores
  `apple` until a macOS adapter exists (the same Swift provider would
  compile for the Mac, but the desktop shell is Tauri; a later decision).
- **Triage** has the same shape: `triage.classifier` (`apple` | `jev`),
  the same fallback, and the on-device classifier runs at the end of each
  sync round under the same per-round bound, on the same inputs Jev gets
  (subject, snippet, sender — never the body). The model fills a
  `@Generable` struct — a priority and label *names* from the list it was
  given — and the engine keeps only ids it knows.

### What changes per feature

| Feature | Today | With the on-device model |
| --- | --- | --- |
| Summarize thread / group | one completion | same prompt; the Swift provider **splits a prompt that does not fit** (4,096 tokens on iOS 26; ~9,000 characters of prompt budgeted) on its blank lines, answers each part under the same instruction, then answers the answers — a summary of summaries, never an error. The group summarizer's "active rows" bound keeps most groups under the limit. |
| Draft reply | one completion over the transcript | same, with the transcript truncated to the newest messages that fit |
| Edit with AI (tone presets, instruction) | one completion | same; short inputs, fits comfortably |
| Jev triage (priority + labels) | `adapter-jev`, BYO key | **done**: `TriageCall`, a `@Generable` struct `{ priority, labels: [String] }` with the Settings label names in the prompt; the engine maps names to ids and drops the rest. Jev stays selectable (Settings › Triage › Classifier). |
| Attachments | none | later, if iOS 27 image input holds: "what is this attachment" on an image attachment from Quick Look |
| Longer threads | — | **later**: iOS 27's Private Cloud Compute option, behind its own toggle, default off — it is Apple's cloud, not ours, but it is a network hop the README promises does not exist by default. Not built until the API is confirmed; today a long thread is summarized in parts (below). |

Quality expectation to set in Settings copy: the on-device model is small.
Summaries and edits are good; drafting a careful reply is where OpenAI stays
better. Streaming: `AiProvider::complete` returns a whole string by design;
the summary sheet is the first place a `Stream` would pay off, and the port
comment already names it as the one call site to widen.

### Verify on the first build

`SystemLanguageModel.Availability.UnavailableReason` case names used in
`AppleIntelligenceProvider.unavailableReason`; the
`LanguageModelSession.GenerationError` cases named in `describe`; that
`@Guide(.count(0...3))` on a `[String]` compiles. The label names are put
in the prompt and matched case-insensitively against the Settings list
afterwards (a runtime `anyOf` constraint was not relied on). The iOS 27
provider protocol is not a goal: the Rust adapter already works and the
desktop needs it.

## Step 6 — widgets, Live Activities, Controls

Widgets run out of process, so they get a **snapshot, not the engine**
(`Shared/WidgetShared/`, compiled into the app and both extensions;
`HeyPigeonWidgets/` is the extension):

- An App Group (`group.app.heypigeon`) with one JSON file,
  `widget-snapshot.json`: unified unread, per-account unread, the due and
  the upcoming reminders (five each), the Need reply rows (five) and total,
  the last sync time. `WidgetSnapshotWriter.publish` runs at the end of
  every `AppModel.reload()` and writes + `reloadAllTimelines` only when
  the content changed. The timeline provider schedules one extra entry at
  the next reminder's time, so "Next reminder" flips to "Due" on its own
  while the app is asleep.
- Widgets: **Unread** (small, plus the Lock Screen accessories: the count
  and one bar per account in its colour), **Next reminder** (medium: the
  row, Done, and Snooze 1 h when due), **Need reply** (medium and large:
  up to five rows, each with Done).
- **Buttons run in the app's process.** `WidgetMarkDoneIntent` and
  `WidgetSnoozeIntent` are `LiveActivityIntent`s — the one intent kind the
  system performs in the app rather than the extension without opening the
  app — so a Done from a widget is `AppModel.markDone`, same optimistic
  path, same outbox. The intent types are compiled into both targets (the
  system needs that); their bodies call a hook (`WidgetActions.handler`)
  the app installs at launch, so the shared file never references
  `AppModel`.
- **Live Activity** (`ReminderLiveActivity`): one for all reminders that
  are due, showing the first — sender, subject, Done · 1 h, tap to open —
  on the Lock Screen and in the Dynamic Island. iOS lets only the app in
  front start one, so `ReminderLiveActivityController.sync` runs on every
  activation and on the 30 s tick that notices a reminder coming due; it
  updates as the set changes and ends when it empties. The local
  notification still fires for the asleep case.
- **Controls** (`Controls.swift`): Compose, Scheduled, Inbox — each an
  `OpenHeyPigeonIntent` (an `OpenIntent`, as Apple requires for a control
  that opens the app) with a `ControlTarget` enum, routed through the same
  hook to `AppModel.handle(DeepLink)`.
- **Deep links**: `heypigeon://thread/<id>`, `heypigeon://compose`,
  `heypigeon://folder/<name>` (`Shared/DeepLinks.swift`, `.onOpenURL` in
  `HeyPigeonApp`). The widgets' taps and the Live Activity use them.

**Not** in this step: moving SQLite into the App Group. The snapshot covers
every widget above. The move happens if and when an App Intents extension
is needed for latency, and it is a one-time data-directory migration in
`HeyPigeonApp.makeEngine` (copy if the group container is empty, then open
there), with the Keychain items moved to an access group at the same time.

### Signing

The extensions are their own bundle ids (`app.heypigeon.ios.widgets`,
`app.heypigeon.ios.share`), each with its own App Store profile, and all
three carry the App Group. `publish-ios.yml` creates the two App IDs and
enables the App Groups capability on all three through the App Store
Connect API (tolerating "already exists"), fetches three profiles with
`sigh`, and names each target's profile through `PROFILE_APP` /
`PROFILE_WIDGETS` / `PROFILE_SHARE` build settings that `project.yml` maps
onto `PROVISIONING_PROFILE_SPECIFIER` per target (empty under local
automatic signing).

**One-time portal step.** The App Store Connect API has no App Groups
resource, and fastlane's `produce group` / `associate_group` need an Apple
ID session, so the group itself is made by hand once: developer.apple.com →
Certificates, Identifiers & Profiles → Identifiers → App Groups → register
`group.app.heypigeon`; then on each of the three App IDs → App Groups →
Configure → tick it. Until that is done the workflow's profile step fails
fast with these clicks (it decodes each profile and looks for the group),
and the next run regenerates the profiles with it.

## Share extension

`HeyPigeonShare/`: the share sheet's "Hey Pigeon" for text, links and files
(images, PDFs, anything, up to the composer's 18 MB cap each). An extension
cannot send mail and must not try: it writes the items into the App Group
as a `PendingShare` (files alongside), then opens the app on
`heypigeon://compose` through the responder chain — and whether or not
that works on a given iOS, the app turns a pending share into a prefilled
composer the next time it is in front (`AppModel.adoptPendingShare`). The
subject is the shared title when there is one; links go under the text;
nothing is sent until Send.

## Settings

A new section, between **AI** and **Triage**:

- **Siri & Search** — *Let Siri see your inbox* (the Spotlight index);
  *Siri Shortcuts* (opens the system's App Shortcuts page); a line that
  says what leaves the device: "Nothing. Siri reads the index on this
  iPhone." updated if iOS 27's cloud reasoning turns out to apply.
- **AI** gains the provider row at the top: *On this iPhone* (Apple
  Intelligence, when available) · *ChatGPT (OpenAI)*; *Use Apple's Private
  Cloud Compute for long threads* (off); the existing key, model and
  Auto-summarize rows apply to the OpenAI provider only.
- **Triage** gains *Classifier*: *On this iPhone* · *Jev*.

## Milestones

Ordered by what unlocks what. Each step is its own PR; none needs a Mac
build of the previous one to be *written*, all need one to be *shipped*.

| # | Step | Touches | Verify before starting |
| --- | --- | --- | --- |
| 1 | Entities, the intent table, `AppShortcutsProvider`; `Intents/` folder; `NSUserActivityTypes` and the App Shortcuts entries in `project.yml` | Swift only | that in-process intents launch the app in the background on iOS 26 as documented (they have since 16) |
| 2 | `IndexedEntity` + index refresh in `sync()`; the Siri & Search setting | Swift only | `IndexedEntity` attribute set; indexing budget on cold launch |
| 3 | Mail schema domain | Swift only (the latest-message mapping needs no engine change) | macro acceptance of the extra initialisers; entitlement / distribution requirements |
| 4 | On-screen awareness, `RemindMe` follow-up, long-running intents | Swift only | iOS 27 multi-turn / long-running protocol names |
| 5 | Foundation Models provider; triage classifier; provider pref; Settings › AI | Swift + `crates/ffi` (`AiBackend` foreign trait, provider and classifier resolution); `core` untouched | `UnavailableReason` and `GenerationError` case names; `@Guide(.count)` on arrays |
| 6 | Widget extension, App Group snapshot, Live Activity, Controls | Swift + `project.yml` (second target, App Group entitlement) + `publish-ios.yml` (three profiles) | nothing iOS-27-specific; the first CI run creates the App IDs and group |
| 7 | Share extension | Swift + `project.yml` (third target) | that the responder-chain open still works on iOS 26; the app picks the share up on launch regardless |

All seven steps are implemented in the PR stack that follows #54; none has
been compiled on a Mac yet. Step 1 was the one to do first regardless of
what iOS 27 turns out to be:
it is documented iOS 16–26 API, it is already on the roadmap, and every
later step builds on its entities. Steps 2 and 5 are where the iOS 27 story
pays off. Steps 3 and 4 are the ones most exposed to the unverified claims
and should be re-planned against Apple's docs when they start.

### Testing without a Mac

- Entities and intents are pure Swift over `MailEngine`; `MockEngine`
  stands in, as it does for the UI. Unit tests target the intent `perform`
  bodies through `AppModel` with the mock, same as any action.
- The `crates/ffi` additions (`AiBackend`, `message(id)`) are tested on Linux
  CI like the rest of the bridge: a Rust test implements the foreign trait
  in Rust and drives `ForeignAiProvider` through `core`.
- Siri phrases, Spotlight and widgets need a device. That is the Mac step,
  with the existing TestFlight workflow.

## Risks and the things that stay as they are

- **`NewMailNotifier` uses SiriKit's `INSendMessageIntent`** for
  communication-style banners. It is still the documented way to get the
  sender's name and avatar on a notification; keep it, expect deprecation
  warnings, and check whether iOS 27 moved communication notifications to
  App Intents. If it did, that is a two-file change in the notifier.
- **Siri and privacy.** The index carries subject, sender and a snippet.
  That is what a notification shows on the Lock Screen already, so it is
  not new exposure to the device; the new exposure, if any, is Siri's own
  reasoning path, which is why the setting exists and defaults can be
  revisited once Apple documents it.
- **Cold-launch latency** for background intents: the engine opens
  SQLite and the Gmail adapter before `perform` runs. Measure on device; if
  it is over a second, an App Intents extension with the App Group move is
  the fix, not a cache.
- **Model quality** on-device is a step down from GPT for drafting. The
  Settings copy says so; the provider pref makes the upgrade one tap.
- **Context limit** on-device is small. The chunking in step 5 is required,
  not optional; a thread that does not fit must degrade to "summary of the
  newest messages", never to an error in the summary card.
- **Nothing here adds a server.** Private Cloud Compute is Apple's, off by
  default; Siri's cloud path is Apple's, behind the index toggle. The
  README's promise holds.

## iOS 27

The deployment target is iOS 27 (#63; `docs/ios.md` "Platform floor"), and
the seven features below are built on the iOS 27 SDK APIs named in their
issues. As with the steps above, **none of this has been compiled on a
Mac**: the Swift was written against the WWDC26 session names, each
API-touching call sits in one small place, and the "verify on the first
build" list at the end says exactly which names to check.

### One model layer (#65, #69)

Every AI call on iOS goes through **`FoundationModelsBackend`**
(`AI/FoundationModelsBackend.swift`), the one `AiBackend` the Rust core
calls back into, over a **`ModelProvider`** (`AI/ModelProviders.swift`)
picked per request by the core:

| id | provider | window | leaves the device |
| --- | --- | --- | --- |
| `apple` | `SystemModelProvider` — Apple Intelligence on device | ~4K tokens (9,000 chars budgeted, chunked) | no |
| `apple-cloud` | `PrivateCloudComputeProvider` — `PrivateCloudComputeLanguageModel`, light reasoning for drafts and summaries, deep for triage | 32K tokens (100,000 chars) | Apple's servers, never stored, no key |
| `openai` | the Rust `adapter-openai` client, as before (the desktop needs it) | per model | OpenAI, BYO key |
| any | `PackageModelProvider` — a Swift package's `LanguageModel` (Anthropic's or Google's once published, a local MLX model for a small fine-tuned classifier), its token in the Keychain (`ProviderTokenStore`), never an API-key string in the binary | per model | per provider |

- The engine holds **one backend per provider id** (`add_ai_backend` /
  `remove_ai_backend` in `crates/ffi`), accepts the known ids whether or
  not this device registered them (the choice is synced), and resolves the
  active provider as the **preferred one, then the first of
  `pref:ai.fallback` that can answer** (default on device → Apple's cloud →
  OpenAI, the order of how much leaves the device). Classifiers follow the
  same rule with Jev last. `RustEngine.refreshAIProviders` re-registers
  before every sync, so an offline cloud model drops out and the device
  model answers.
- **Settings › AI** lists both Apple rows (answering · available · why
  not), *Prefer*, *If it can't answer* (private first · cloud first · stay
  on this iPhone) and a per-provider token line from `AiUsageLedger`
  (`response.usage` after every answer; a cost estimate when a price is
  known). The classifier picker gains Apple's cloud.
- The **Private Cloud Compute entitlement** is granted per App ID on
  request; `project.yml` carries the key commented out with the steps. Until
  it is granted the app degrades to the on-device model on its own.
- **Evaluations** (`HeyPigeonTests/Evaluations/`): a labeled triage set
  (`triage-eval.json`, placeholder rows to replace with anonymised mail),
  `TriageEvalScore` / `TriageEvalReport` (priority accuracy, near misses,
  label precision / recall / F1, one overall number to climb) over every
  `TriagePromptVariant` (`AI/TriagePrompt.swift`, where the shipped
  instruction lives), and a summary harness with a format-and-grounding
  checker against the engine's shipped prompt (`ai_prompts` over the FFI).
  The pure parts run anywhere; the model runs are enabled on a device with
  Apple Intelligence and print the per-variant report. Wrapping the report
  in the Evaluations framework's graders is the on-Mac step.

### Ask my inbox (#64)

`AI/InboxAsk.swift`: a session on the on-device model with iOS 27's
**`SpotlightSearchTool`** over this app's own index (the `Communications`
content domain, a `ContactResolver` made of the account addresses),
answering a `@Generable InboxAnswer` — the text and the ids of the results
it rests on, validated against the store and listed under the answer,
tappable (`Features/Inbox/AskSheet.swift`, streamed). The inbox toolbar,
Settings › Siri & Search and `AskInboxIntent` ("Ask Hey Pigeon when the
Lisbon flight is") open it. To make the answers good the index got richer:
participants with addresses, Gmail label names, the account handle, and —
for threads the store holds bodies of — the newest messages' text as
`textContent`, capped at 4,000 characters, through
`MailEngine.threadLocal` (`Engine.get_thread_local`, no fetch for the
index's sake). `SpotlightIndexDelegate` answers reindex requests and the
read-back (`searchableItems(forIdentifiers:)`) so the tool sees full items.
On only while the Spotlight toggle is on; the answer never leaves the
device.

### Agentic triage (#66)

"Hey Siri, triage my inbox in Hey Pigeon". `AI/TriageTools.swift` has the
Foundation Models `Tool`s over `AppModel`: `searchThreads`, `readThread`
(reading) and `setLabel`, `markDone`, `remind`, `markNeedReply`,
`draftReply` (proposing); **delete and send are not tools**. Acting tools
never touch the mailbox: they add to a `TriagePlan` that is confirmed
**once as a batch** ("Mark done 12, label 3 and remind 2?") and applied
through the same model methods as the swipes; drafts go to Drafts, never
out. `AI/TriageAgent.swift` runs three phases, each its own session
profile — *scan* (on device, cheap, names the candidates), *decide*
(Apple's cloud when reachable, else on device; reads only what the preview
does not settle), *act* (on device, tools enabled) — with the user's own
rules from Settings in the instructions and every tool call in
`TriageJournal`. `TriageInboxIntent` is a `LongRunningIntent &
CancellableIntent` with a dry-run parameter; progress is a Live Activity
(`TriageLiveActivity`, Stop through the widget hook). Settings › Triage has
the dry-run switch and the rules (both synced) and "Siri triage and
journal": run from the app, apply or leave as is, read every run back.

### Attachment understanding (#67)

Attachments reach the phone: `MailEngine.attachments` / `attachmentFile`
over the engine's `list_attachments` / `fetch_attachment` (the Gmail
adapter walks the parts tree; embedded parts get `inline:<n>` ids; bytes
are fetched on tap and cached as a file under the data directory, never
auto-opened), as chips under each expanded message that open Quick Look,
with **Explain attachment** on images and PDFs. `AI/AttachmentUnderstanding.swift`
lets the on-device model look at the file — iOS 27 image input
(`Attachment` in the prompt; images downscaled to 1,024 px, a PDF's first
page rendered through PDFKit) with the Vision-backed **`OCRTool`** and
**`BarcodeReaderTool`** — answering a `@Generable AttachmentInsight`
(kind, summary, merchant, total, date, tracking number, carrier, flight,
departure, code). From the fields come one-tap chips on the existing
reminder plumbing: remind me on travel day, remind me before an amount is
due, copy the tracking number or the code. The **triage hook** runs it as
a thread opens when the subject smells like a receipt, ticket or shipment
and an image or PDF is attached (cheap heuristic first). On device only:
an attachment never goes to OpenAI or to Apple's cloud.

### View Annotations and the `.mail.thread` schema (#68)

Inbox and search rows carry
`.appEntityIdentifier(EntityIdentifier(for: MailThreadEntity.self, identifier:))`
and the `List` is a selection of thread entities
(`.appEntityIdentifier(forSelectionType:)`), so "mark these done", "remind
me about the second one tomorrow" and "archive everything from Lufthansa
here" resolve against what is on screen. `MailThreadEntity` adopts
**`.mail.thread`** with its `messages`: `MailMessageEntity` is a real
stored message (id `<threadId>#<messageId>`) whenever the store holds the
thread's messages, and the latest-message shape (id = thread id) only for
a thread never opened; every schema intent acts on the message's
`threadId`. `openMessage` / `openDraft` have their `@AppIntent(schema:)`
back. Both queries answer `displayRepresentations(for:requestedComponents:)`
from the rows alone.

### Siri's model of the app (#70)

`MailThreadEntity` and `MailDraftEntity` are `SyncableEntity` (Gmail
thread ids and draft keys are stable across devices) and the thread states
its ownership explicitly (`OwnershipProvidingEntity`, private by default).
Reminder and new-mail notifications carry `appEntityIdentifiers` for their
thread. `Intents/IntentDonations.swift` donates the schema-shaped actions
when the user performs them in the UI — archive, delete, reply, label,
remind — through `IntentDonationManager.shared.donate(intent:result:)`,
from the swipes, the row menu, the thread bars and the Remind sheet only:
never an intent Siri just ran, never a sync, never the agent.

### Verify on the first build (iOS 27)

Each of these is one call in one file; a renamed API is a local fix.

| What | Where |
| --- | --- |
| `PrivateCloudComputeLanguageModel` and its `availability` cases; `ContextOptions(reasoningLevel:)` with `.light` / `.deep`; `LanguageModelSession(model:contextOptions:tools:instructions:)` | `AI/ModelProviders.swift` |
| `response.usage` and its `inputTokens` / `outputTokens` | `AI/AiUsageLedger.swift` (`record(provider:_:)`) |
| `SpotlightSearchTool.Configuration` (`contentDomain = .communications`, `contactResolver`), `ContactResolver` / `ResolvedContact` | `AI/InboxAsk.swift` |
| `CSSearchableIndexDelegate.searchableItems(forIdentifiers:)`, `CSSearchableItem.associateAppEntity`, the `accountIdentifier` / `accountHandles` / `mailboxIdentifiers` attributes | `Intents/SpotlightIndexer.swift`, `Intents/Entities.swift` |
| `LongRunningIntent`, `CancellableIntent` requirements | `Intents/TriageIntents.swift` |
| `Attachment(image)` in a `Prompt`, `OCRTool()`, `BarcodeReaderTool()` | `AI/AttachmentUnderstanding.swift` |
| `@AppEntity(schema: .mail.thread)` property requirements, `.mail.openMessage` / `.mail.openDraft`, `displayRepresentations(for:requestedComponents:)`, `.appEntityIdentifier(forSelectionType:)` | `Intents/Entities.swift`, `Intents/MailSchema.swift`, `Intents/MailSchemaIntents.swift`, `Features/Inbox/InboxView.swift` |
| `SyncableEntity`, `OwnershipProvidingEntity` / `EntityOwnership`, `UNMutableNotificationContent.appEntityIdentifiers`, `IntentDonationManager.shared.donate(intent:result:)` | `Intents/Entities.swift`, `Shared/ReminderScheduler.swift`, `Shared/NewMailNotifier.swift`, `Intents/IntentDonations.swift` |
| The Private Cloud Compute entitlement key, once access is granted | `ios-app/project.yml` |
| `LanguageModelSession.DynamicProfile` — the agent's three phases are plain sessions per phase (`TriageProfile`); move them onto a dynamic profile when the API is in hand | `AI/TriageAgent.swift` |
| AppIntentsTesting over the schema intents (the Swift Testing tests cover the `perform` bodies today) | `HeyPigeonTests/MailSchemaTests.swift` |

## Out of scope

macOS Siri (the desktop shell is Tauri; App Intents need a native target —
a future Swift menu-bar helper could reuse every entity above, but nobody
is asking), visionOS and watchOS apps (the Watch gets the App Shortcuts for
free), Visual Intelligence lookups (no mail entity is a thing you point a
camera at), and any custom Siri voice UI beyond the snippet views above.
