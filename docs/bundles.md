# Bundles

A **bundle** groups the mail about one specific thing: a trip, an order (or a
season of orders, like Christmas shopping), a project. The AI fills it,
the user can always correct it, and every correction teaches it. Opening a
bundle shows a summary of the key facts first, then its threads.

Status: built — bundles make themselves (the model groups new mail:
"Automatic bundles" below), shared booking, order and tracking numbers link
mail, key facts, the chip, the Bundles list, the bundle view, "Add to
bundle…", and folded inbox rows on iPhone and iPad. Not built yet: the AI
narrative and attention line, auto-archive, folding on the Mac. Code:
`crates/core/src/bundles.rs` (extraction, linking, facts),
`crates/ffi/src/bundles.rs` (the engine API and the model pass),
`ios-app/HeyPigeon/AI/BundlePrompt.swift` (the prompt),
`ios-app/HeyPigeon/Features/Bundles/BundleViews.swift` (the screens),
`AppModel.fold` (folding).

## The bundle view (as built)

Top to bottom:
- **Summary** — the model's brief (`ai_summarize_bundle`): a STATUS line
  (where things stand, the latest decision or change) and up to three TO DO
  lines for the user ("Send the invoice to Acme", "Write the project
  brief"). It reads the newest eight emails, their text when stored (fetched
  for the summary otherwise). It runs on open when the model is on this
  device or auto-summarize is on, otherwise on a tap, like every summary.
- **Tracking** — links found in the bundle's mail whose address or link text
  says "track", or that carry a tracking number; a tracking number's fact
  gets a Track button with its link.
- **Key facts**, then the emails, open first, done dimmed and folded past
  three.
- Every email row works like an inbox row: the same swipes, the same
  long-press menu, and the thread opens inside the sheet. The shared sheets
  (Remind me, Add to bundle, the composer, a summary) are presented by the
  Bundles sheet while it is open (`AppModel.modal`).
- **⊖ on each email** (and "Not part of …" in the row menu): the email
  leaves the bundle, never comes back to it, and its subject becomes a "not
  this" example the model sees for that bundle.

## Automatic bundles (as built)

The user does not make bundles; they fix them. After each sync round the
shell's model (on device or Apple's cloud, never ChatGPT) reads each new
email from the last 30 days that is in no bundle — sender, subject and
preview line only, never the body — together with the active bundles (name,
kind, a few subjects each), and answers one of:
- **join** a listed bundle (by its exact name),
- **new**: a trip ("Lisbon trip"), shopping ("Zalando order", "Christmas
  shopping") or project ("Acme website") bundle no listed one covers,
- **nothing**: newsletters, promotions, notices, monthly bills, chat.

Rules around the answer (`ffi::bundles`):
- Each email is asked about once per message (`threads.bundle_ai_msg_count`),
  at most 10 per round, the batch read oldest first so the first email about
  a trip names it.
- A new name equal to a listed one joins it; a bare kind ("Shopping") is
  refused, so no catch-all bundle forms.
- A model bundle is **hidden until a second email joins** (one receipt is not
  a bundle) and is dropped if it still holds one email after three weeks.
- The model's bundles stay **on this device**: every device groups its own
  mail, like triage. Any user edit — remove an email, add one, rename,
  archive — **adopts** the bundle: it becomes the user's and syncs. A synced
  bundle arriving with the same name and kind as a local model bundle
  absorbs it, so two devices end up with one.
- An email the user removed is never put back in that bundle.
- Settings › AI › "Make bundles" (`pref:bundles.auto`, unset = on).

This replaces "Suggested bundles" below: the model creates instead of
proposing, and the hidden-until-two rule does the job the suggestion card
was for.

## Bundles vs. triage labels

| | Triage label | Bundle |
| --- | --- | --- |
| Is a | kind of mail ("Shopping", "Travel") | one specific thing ("Lisbon, Dec 12–16") |
| Lifespan | forever | ends (trip over, parcel delivered, project closed) |
| Count | a fixed handful from Settings | a few active at a time, many archived |
| Answers | "what is this email?" | "what is this email *part of*?" |

Because bundles end, the active list stays short on its own. That keeps the UI
small and keeps the model's choice small (see "Assignment").

## Goals and non-goals

Goals:
- A thread joins the right bundle without the user doing anything, in most cases.
- Creating a bundle by hand takes one action, and from then on it fills itself.
- Opening a bundle answers "what do I need to know?" before any email is read.
- No new chrome: one row chip, one sidebar entry, one thread action.

Non-goals (v1):
- Gmail labels for bundles. Bundles are app-local state and sync through devsync
  ("Storage"), so the user's Gmail stays clean.
- A thread in several bundles. One thread, at most one bundle. This keeps the
  chip, the picker and the model's answer simple. Revisit if real use asks for it.
- Bundles without mail (notes, manual facts).
- A server. Everything runs on the device, on the provider the user already
  chose (`ai.provider`), under the same rules as triage.

## Model

> As built (SQLite v19): membership is two columns on `threads`
> (`bundle_id`, `bundle_source`: user | link) rather than `bundle_threads`,
> because a thread is in one bundle at most. Anchors live in
> `thread_anchors (thread_id, anchor)` with `threads.anchors_msg_count`
> (the triage versioning rule), exclusions in `bundle_exclusions`. Facts are
> derived from the anchors on read (`core::bundles::bundle_facts`), so there
> is no `bundle_facts` table yet; `bundle_summaries` comes with step 3. The
> sync keys are `bundle:<id>` (app-wide) and `bundle_thread:<thread_id>`
> (`{ "bundle", "excluded" }`) on the thread's account file.
> The sketch below is the full design.

```text
bundles (
  id            TEXT PRIMARY KEY,   -- random, app-wide (like triage_labels)
  name          TEXT NOT NULL,      -- "Lisbon trip"
  kind          TEXT NOT NULL,      -- trip | shopping | project | other
  description   TEXT,               -- one line, the user's words; goes in the prompt
  icon          TEXT,               -- SF Symbol name; defaulted from kind
  status        TEXT NOT NULL,      -- suggested | active | archived
  origin        TEXT NOT NULL,      -- user | ai
  starts_at     INTEGER,            -- extracted or set; trips and orders
  ends_at       INTEGER,            -- drives auto-archive
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
)

bundle_threads (
  bundle_id     TEXT NOT NULL,
  account_id    TEXT NOT NULL,
  thread_id     TEXT NOT NULL,
  source        TEXT NOT NULL,      -- link | ai | user | excluded
  confidence    REAL,               -- ai only
  added_at      INTEGER NOT NULL,
  PRIMARY KEY (account_id, thread_id)   -- one bundle per thread
)

bundle_facts (
  bundle_id     TEXT NOT NULL,
  key           TEXT NOT NULL,      -- "flight:LH1172", "order:112-334", "hotel"
  kind          TEXT NOT NULL,      -- flight | stay | ride | order | parcel | deadline | note
  payload       TEXT NOT NULL,      -- JSON: the typed fields, see "Summary"
  source_thread TEXT NOT NULL,      -- every fact links back to its email
  updated_at    INTEGER NOT NULL,
  PRIMARY KEY (bundle_id, key)
)

bundle_summaries (
  bundle_id     TEXT PRIMARY KEY,
  narrative     TEXT,               -- 2–3 lines, model-written
  attention     TEXT,               -- the one "what needs attention" line
  input_hash    TEXT NOT NULL,      -- threads + facts it was built from
  built_at      INTEGER NOT NULL
)
```

`source` on `bundle_threads`:
- `link`: joined through a hard link (same booking ref, order number,
  tracking number, reply chain). Near-certain.
- `ai`: the model put it there.
- `user`: the user added it. **Sticky**: never moved by the AI.
- `excluded`: the user removed it. **Sticky**: the AI never puts it back, and it
  is a negative example for that bundle.

The `excluded` row needs its own key so it can coexist with membership in another
bundle. Implementation detail: keep exclusions in a separate
`bundle_exclusions (bundle_id, account_id, thread_id)` table if the primary key
above gets in the way.

## Assignment

It runs at the end of each sync round, after triage, on threads that are new or
changed since the last round. Same inputs as triage: subject, snippet, sender
(never the body), plus whatever facts the extraction step found. Same
per-round limit.

### 1. Extraction (no model)

A deterministic pass in the core pulls **anchors** out of subject, snippet,
sender and the attachment insights we already have (`AttachmentInsight`:
`confirmationCode`, `trackingNumber`, `flight`, `departure`, `merchant`,
`total`, `date`):

- booking or confirmation codes, order numbers, tracking numbers (with carrier),
  flight numbers, invoice numbers
- the sender's domain (`booking.com`, `acme.io`)
- Gmail thread and `In-Reply-To` chains (already threads, but a forwarded
  confirmation starts a new one)

Anchors are stored per thread (a small `thread_anchors` table) so a later email
can match an earlier one.

### 2. Hard links

A thread sharing an anchor (other than a generic sender domain) with a thread
already in a bundle joins that bundle with `source = link`. The shipping email
with order `112-334` joins the bundle holding the invoice for `112-334`. This
layer should carry most of shopping and travel.

### 3. The model, as a closed choice

For a thread with no hard link, and only when at least one bundle is active,
ask: *"Which of these bundles is this email part of, or none?"* It's the same
shape as `TriageCall`: a `@Generable` answer the engine validates.

```swift
@Generable
struct BundleCall {
    @Guide(description: "The id of the bundle this email belongs to, or empty for none.")
    var bundleId: String
    @Guide(.range(0...1))
    var confidence: Double
}
```

The prompt lists **only active bundles** (cap: 8, most recently touched first).
For each one it gives:
- name, kind, the user's description
- dates when known ("Dec 12–16, Lisbon")
- up to 3 example subjects from `user` and `link` members (positive)
- up to 2 subjects from `excluded` threads ("not this")

The engine keeps the answer only when the id is one it sent and
`confidence ≥ 0.7`. Between 0.5 and 0.7, it records a **suggestion** shown in the
thread view ("Add to Lisbon trip?"), never a membership. Anything lower is
dropped.

A closed choice over a handful of named bundles is a task the small on-device
model does well. Inventing topics is not, so the model never does it here.

`AiBackend` gains `classify_bundle(subject, snippet, from, anchors, bundles) →
BundleVerdict` next to `classify`, implemented by `FoundationModelsBackend` and
the OpenAI adapter. Same provider fallback rules as triage.

### 4. Learning from the user

There is no training: what the AI learns lives in the prompt, and the user's
edits fill it.
- Adding a thread by hand makes it a positive example and its anchors start
  hard-linking.
- Removing a thread makes it a negative example.
- Editing the description changes the prompt directly.

So "create a bundle, add two emails" is enough for it to start recognizing that
bundle.

## Suggested bundles (AI-created)

The AI **proposes**, never creates silently. Once per sync round, a cheap
clustering pass looks at recent unbundled threads:
- **Trip**: a flight or ticket plus a stay (hotel, Airbnb) with overlapping dates,
  or an outbound and return flight.
- **Order**: 2+ threads sharing an order number from the same merchant.
- **Project**: 3+ threads in 14 days sharing a non-personal sender domain or a
  recurring participant set plus a common subject token. This is the weakest
  signal, so it needs the most evidence.

A cluster of ≥ 3 threads (≥ 2 for an order) becomes a `status = suggested`
bundle. The model names it from the members' subjects and facts ("Lisbon trip",
"Zalando order"). It shows as **one** quiet card at the top of the Bundles list,
with no inbox banner:

> **Bundle 4 emails as "Lisbon trip"?** Accept · Edit · Dismiss

- **Dismiss** remembers the cluster's anchors so the same suggestion doesn't come
  back.
- **At most one** suggestion shows at a time.
- Suggestions expire after 7 days.

## Lifecycle

| Kind | Ends when | Then |
| --- | --- | --- |
| trip | `ends_at` (last return flight or checkout) + 3 days | archived |
| shopping | every parcel delivered (or 14 days after the last order with no tracking) | archived |
| project | the user archives it | — |
| other | 60 days without a new thread | archived |

- Archived bundles leave the active list and the model's prompt.
- They stay searchable (`bundle:` operator, cmd+k).
- A new email that hard-links to an archived bundle reopens it. Returns, refunds
  and "how was your stay" emails land where they belong.
- The model never assigns to archived bundles.

## Summary

The summary is the first thing in the bundle view. It has two parts, and only the
second is model-written.

### Key facts (structured, mostly no model)

They're built from `bundle_facts`, which extraction and attachment insights
fill. Each fact shows with its source: tapping it opens the email it came from.
- **Trip**: dates and destination; each flight (number, route, time, seat when
  present); stay (name, address, check-in and check-out, booking ref); trains,
  cars, events; **gaps** ("no stay for Dec 15", "no return flight").
- **Shopping**: each order (merchant, total, date, status: ordered, shipped,
  delivered); tracking number with carrier; return deadline when stated; a
  running total for multi-order bundles ("Christmas 2026 · 6 orders · €412").
- **Project**: next deadline, open questions, who is waiting on whom (from
  `needs_reply` and follow-up markers already in the threads).

A later email updates a fact rather than adding a duplicate, because facts are
keyed by their anchor (`flight:LH1172`, `order:112-334`). A changed flight time
overwrites the old one and shows "changed" for a day.

### Narrative and attention line (model)

- **Narrative**: 2–3 lines on where things stand, written over the facts plus the
  bundle's threads, using the existing group summarizer (which already splits
  long input on the on-device model).
- **Attention**: one line, the most useful thing on the screen: "Check-in opens
  tomorrow 09:00", "Parcel 2 of 3 still not shipped", "Jana is waiting on the
  budget". It's derived from facts and dates first, and the model is used only
  for projects.

Both are cached in `bundle_summaries` and rebuilt only when `input_hash` changes
(a thread joins or leaves, or a fact changes), never just because the bundle was
opened. The attention line depends on the date, so it's recomputed from the facts
on open (cheap, no model) and is the only part that is.

## Done items

"Done" means archived, as everywhere in the app.

- **The inbox** hides done mail, as today. The inbox is a to-do list.
- **A bundle shows done mail**, quieter. A bundle is a reference: the boarding
  pass archived weeks ago is exactly what's needed at the airport. Hiding done
  mail would empty a trip bundle as the user cleans up the inbox.
  - Open threads come first at normal weight. Done threads follow in the same
    timeline, dimmed.
  - With more than 3 done threads, they fold into a "6 done" row that expands
    on tap.
  - A trip's timeline sorts by **event date** (outbound flight, stay, return),
    not by received date, when facts give one.
- **The summary always uses everything**, done or not.
- **Trash and spam** never appear in a bundle or its summary. A trashed thread
  leaves its bundle, and its facts go with it unless another thread backs them.

## UI

Three touchpoints. Nothing else is added.

1. **Row chip.** One small chip (icon + short name) on rows in a bundle, next to
   the triage chips. At most one, because a thread is in at most one bundle.
   Tapping it opens the bundle.
2. **Bundles.** A section of the sidebar right under the inboxes (as built,
   both apps): the five most recently active bundles with their open
   counts, "N more" for the rest, then "All bundles", which opens the full
   list (archived ones at the bottom). A bundle can be hidden from the
   section (context menu, or the eye in the full list;
   `pref:sidebar.hidden_bundles`, synced); "N more" shows hidden ones too,
   so they can be shown again. A bundle opens its view as a sheet.
3. **Add to bundle…** One thread action (swipe menu, context menu, keyboard
   `b`). It opens a picker with the model's best guess first, then the other
   active bundles, then **New bundle…** (name, kind, an optional one-line
   description). With several threads selected, the same action offers **New
   bundle from these**. In a bundle, **Remove from bundle** marks the thread
   `excluded`.

Bundle view, top to bottom:
- name
- key facts
- narrative and attention line, with a ✨ refresh
- open threads
- the done fold

Bundle actions: rename, edit description, archive or reopen, delete (removes
the bundle, never the mail).

### Folded inbox rows

On iPhone and iPad, a bundle's **quiet** inbox mail shares one row:
"✈ Lisbon trip · 3 updates · Seat chosen, Your receipt, …". Mail that
needs the user keeps its own row, with the chip. A thread is quiet when it
is:
- read
- not high or medium priority (triage)
- not flagged Need reply, no reminder, no open AI suggestion
- not pinned, not a draft

A bundle folds only with **two or more** quiet threads in the inbox; one
alone stays a normal row. The folded row sits at the top of the day group
of its newest email. Tapping it opens the bundle; its swipe (and its menu)
is **Mark all done**, with one Undo. Folding applies to the plain inbox
only: a search, a label filter or another folder lists every thread.

It is on by default (Settings › "Fold bundle updates", `pref:bundles.fold_inbox`,
synced), because only mail that asks nothing of the user folds. The Mac
lists every thread with its chip for now: its keyboard selection walks
threads, and a folded row needs its own place in that map.

## Storage and sync

- The tables live in the SQLite store next to `triage_labels`, through
  `adapter-sqlite` with a schema migration.
- They sync through devsync like triage labels:
  - `bundle:<id>`: the bundle row, app-wide
  - `bundle_thread:<account>:<thread_id>`: membership with source, per account
  - user exclusions, which must sync because they are user intent
- `link` and `ai` memberships, facts, anchors and summaries stay local. Every
  device recomputes them, the same rule as "Jev's own results stay local".
- Prefs: `bundles.fold_inbox` (unset = on). Later: `bundles.suggest`
  (default on) with suggested bundles.

## Quality

- An **evaluation set** next to `HeyPigeonTests/Evaluations/TriageEvaluation.swift`:
  labeled threads with their correct bundle (or none), scored as assignment
  precision and recall. **Precision matters more**: a wrong email in a bundle
  costs trust, while a missing one costs a tap.
- The 0.7 / 0.5 thresholds are tuned on that set.
- Extraction gets unit tests in the core, against fakes, no network, like the
  rest of `core`.
- Bound per round: at most N `classify_bundle` calls (shared budget with
  triage), oldest-first backlog.

## Rollout

1. **Manual bundles + extraction + hard links.** Built, with folding on
   iPhone and iPad. Tables, devsync keys, the row
   chip, Bundles list, bundle view with key facts and the done fold, "Add to
   bundle…". It's useful without any model.
2. **Model assignment** to existing bundles: `classify_bundle`, thresholds,
   in-thread suggestions, learning from edits, the evaluation set.
3. **Summary narrative and attention line** through the group summarizer.
4. **Suggested bundles and auto-archive.**
5. **Folded inbox rows** on the Mac (built on iPhone and iPad).

## Open questions

- One bundle per thread: is a thread ever really in two (a work trip that is
  also a project)? Start with one, and watch the "Add to bundle" usage.
- Should `kind` stay fixed (trip, shopping, project, other)? It drives facts and
  lifecycle, so a free-form kind would lose both.
- Does a hand-made bundle want date bounds ("only mail after Nov 1")? It's cheap
  to add, and it would make the Christmas-shopping case precise.
