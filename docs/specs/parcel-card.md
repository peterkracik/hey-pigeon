# Parcel card

Status: Implemented — Rust verified locally; Swift awaits `ios-ci` / `macos-ci` and a look on a device (see Verification). PR: #157 (draft)
Related: `docs/bundles.md` (bundles, tracking links, folded rows),
`docs/ios.md` (the inbox list), `macos-app/CLAUDE.md` (the window's list)

## What and why

"Update bundles to follow this": Gmail's "Happening soon" card. Parcels
that are on their way get a card at the top of the inbox — one row per
parcel, what it is, when it is expected, and a **Track parcel** button —
so the question "where is my order" is answered without opening a bundle
or finding the shipping email. A delivered parcel leaves by itself.

The owner decided: the core provides a status, an expected day and an
item title per shipment; one row per parcel, not per bundle; a distinct
card in Gmail's shape (visible Track button, "View details", a "…" menu,
collapsed to the first item with "+N more", "Show less" and "Dismiss all",
an X on the header) in Hey Pigeon's own tokens.

**Out of scope:**
- Product pictures. Loading one is a request to the shop from the inbox,
  which the remote-images default (off, ask per sender) forbids. The
  bundle's icon stands in the thumbnail's place.
- Asking a carrier or a shop anything. Everything on the card is read
  from mail already on the device; a status is as fresh as the last email.
- A model. Nothing here is sent to an AI provider.
- Parcels of mail that is in no bundle, and trips, flights or events
  ("Happening soon" for a boarding time). The card is parcels only.
- The tracking address a shop writes into hidden markup (`trackingUrl`):
  the button only ever opens a link from the email's body, never the
  markup's `trackingUrl`.

## Behaviour

What a parcel is and what is known about it (core):

- R1. A **parcel** is a shipment of an **active** bundle (not archived, not
  a model bundle still forming): its tracking links grouped by the rule of
  the bundle's Info page (`docs/bundles.md`) — links are one parcel when
  the same tracking or order number (six characters or more) from the
  bundle's mail is in both addresses, and an email's links without a
  number belong to that email's first link with one; an email with no
  numbered link is one parcel. Two different numbers in one email are two
  parcels. Within one email the carrier's own link wins over a
  click-redirect's. A link whose host cannot be read the same way by
  every URL parser is never a parcel's link: one that names a user
  before its host (`https://dhl.com@evil.example/`), one with a
  backslash, a control character or a non-ASCII character before its
  path (`https://dhl.com\@evil.example/`), one with a port that is no
  number — and one whose host is an IP address, which names nobody. The
  same number in two bundles is one parcel, the first bundle's.
  The parcel's link and email are the newest email's. Only the bundle's
  fifteen newest threads are read, and none older than 45 days.
- R2. A shipment is a parcel only with a sign that it is one: the bundle is
  a Shopping bundle, or its link carries a tracking or order number, or
  one of its emails has a tracking number, a status or an expected day. (A
  "track your application" link in a project bundle is not a parcel.)
- R3. **Status** is one of *shipped*, *out for delivery*, *delivered*, or
  unknown. **Expected day** is a calendar day, or unknown. **Item title**
  is text, or unknown. They are read, per email, from two places:
  1. schema.org markup the shop embedded (`ParcelDelivery` / `Order`, as
     JSON-LD or microdata): `expectedArrivalUntil` (else `…From`) → the
     day as written; `orderStatus` `OrderInTransit` → shipped,
     `OrderDelivered` → delivered; `itemShipped` / the order's items →
     the title (the first item's name, "+ N more" when there are more).
     It is read from the message as received, when its body is fetched,
     because the sanitizer removes this markup from the stored body.
  2. the subject and the start of the preview line, where the wording is
     unambiguous: "delivered", "out for delivery", "shipped / on its way /
     dispatched" (and Czech, Slovak and German equivalents), never after
     "not", "will be", "to be", "once" and the like; a day only when it
     follows a delivery word ("arriving", "delivery", "expected", …) as
     "today", "tomorrow", `2026-11-20`, `20.11.2026`, `20.11.`, "Nov 20"
     or "20 November". The title is never read from text.
- R4. Nothing is guessed. A day outside 30 days before to a year after
  its email is dropped. "Today" / "tomorrow" count from the day the email
  arrived in this device's time zone. A weekday alone ("arriving Friday")
  and `11/20` are not read. No day known → the row has no day.
- R5. Across a parcel's emails: the status is the furthest one any of
  them states; the day and the title are the newest email's that has one,
  markup before text within one email.
- R6. A parcel leaves the card by itself: 24 hours after the email that
  said *delivered*; else 3 days after its expected day; else, with no day
  known, 14 days after its newest email.
- R7. Order: parcels with a day first, the earliest day first (*out for
  delivery* counts as today); then the ones without, newest email first;
  delivered ones last. At most 12.
- R8. Hostile mail: markup is parsed with bounds (8 blocks of at most
  64 KB, nesting 6 deep), a title is plain text of at most 120
  characters with control, invisible and direction-changing characters
  removed (zero-width and bidi controls, the soft hyphen, filler letters,
  tag characters) and at most three combining marks on a letter, and no
  value from markup is ever used as an address. A parse that fails
  yields nothing. Reading links from a body is linear in its length: a
  link's text is looked for only after a quoted address and within 512
  bytes.

The card (shared shell):

- R9. The card shows in the **plain inbox** only — the Inbox view with no
  search and no triage-label filter, for one account or all (a parcel
  shows for the account its email is in) — as the first thing in the
  list, above Pinned. An inbox with no mail but a parcel shows the card
  alone, not "All clear". With no parcel to show there is no card.
- R10. Title **Parcels**, an **X** ("Dismiss all"). Collapsed (the
  default): the first parcel and "+N more". Expanded: every parcel, and
  a footer with **Show less** and **Dismiss all**. With one parcel there
  is no footer. Expanded or collapsed is remembered per device.
- R11. A row: the bundle's icon; the item title, two lines at most (the
  bundle's name when no title is known); the status line; **Track
  parcel**; **View details**; **…**.
- R12. The status line, the first that applies: "Delivered"; "Out for
  delivery"; "Expected today / tomorrow / yesterday / Friday / 24 Nov" —
  each followed by the host the Track button opens ("Expected today ·
  track.dhl.com"); else that host, then "Shipped" when that is known,
  else the email's subject, and the email's time ("track.dhl.com ·
  Shipped · 10:12"). **The host is on every form of the line**, and it is
  the link's real host: the title and the subject are the mail's words,
  the host is what the mail cannot dress up. No carrier or shop name is
  shown — not one worked out from the host (`dhl.top` is not DHL) and
  never the sender's display name; a click-redirect shows its own host.
  A parcel that holds folded mail (R17) ends with "· N updates".
- R13. **Track parcel** opens the parcel's link in the default browser
  (`Browser.open`). **View details** opens the bundle on its Info page.
  **…**: a first section headed "Opens <host>" — the host the link
  really leads to — with Track parcel; then Open bundle (Emails page),
  Open email (the parcel's newest email), Mark all done (only when the
  bundle has quiet inbox mail, R18), Dismiss.
- R14. **Dismiss** hides one parcel; **Dismiss all** / X hides every
  parcel now in the card. Both show a toast with **Undo** ("Parcel
  dismissed", "3 parcels dismissed"), which is also on the Undo stack.
  A dismissed parcel **comes back when a newer tracking email arrives**
  for it. Dismissals are a synced pref (`inbox.dismissed_parcels`,
  entries "id@time"; an id is `number:` and the first 16 hex digits of
  the SHA-256 of the parcel's tracking or order number — never the
  number — or `thread:` and its email's Gmail thread id; the same on
  every device). Entries older than 180 days are dropped when the list
  is next written.
- R15. Settings › Inbox › **Show parcels** (`inbox.parcel_card`, synced,
  unset = on): "Parcels on their way get a card at the top of your inbox.
  Worked out on this \(Device.name) from your mail; Track parcel opens
  the email's own link in your browser. Which parcels you dismissed
  syncs to your other devices with your other settings." Off, the reload
  does not ask the store for parcels.
- R16. The items come with the list's reload (one engine call,
  `tracking_overview`), **always read off the main thread**: a reload on
  the main actor (navigation, the user's own actions) carries the
  parcels the model holds and a background reload follows, so the card
  is a moment behind the rows at launch and never costs a tap anything.
  Dismiss and Undo show at once: they filter the list the model holds.
  No view asks the store. A parcel's link is known once its email's text
  is on the device (opened, or fetched ahead on Wi-Fi), as on the Info
  page: until then the parcel is not in the card. Offline changes
  nothing: the card is local.
- R17. Folding (where the inbox folds, R-platform): a bundle with a
  parcel in the card gets **no folded row**; its quiet mail (the mail
  that would have folded: two or more read emails that ask nothing) is
  under the bundle's first parcel in the card, counted on its status
  line ("· 3 updates"), reachable through View details / Open bundle, and
  done at once with Mark all done (one Undo). Mail that needs the user
  keeps its own row, as before. When the parcel leaves the card (R6,
  R14) or the card is off, the folded row is back.
- R18. Mark all done marks the bundle's quiet inbox mail done — the same
  rule and the same action as the folded row's — on every platform.
- R19. Accessibility: a row reads as one element (title, status) with
  Track parcel, View details, Open email and Dismiss as its actions;
  Track parcel is also a button of its own, named with the host it
  opens ("Track parcel, opens track.dhl.com"); targets are 44 pt on touch; at accessibility
  text sizes the buttons stand under each other; a status is words, never
  a colour alone; the expand and collapse honour Reduce Motion.

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core (`crates/core/src/parcels.rs`) | `Delivery`, `ParcelStatus`; `from_markup` (JSON-LD, microdata), `from_text`; `remember_deliveries` (after a full fetch) and the text pass in `bundles::link_pass`; `overview` (R1–R7). `Message.delivery` carries what the Gmail adapter read before sanitizing (`adapter-gmail` `full_fetch`), as `open_token` does. Port: `Store::set_thread_deliveries`, `thread_deliveries` (default impls; `MemStore`, SQLite), and `Store::list_recent_bundle_threads` (the overview's fifteen newest threads of the window, by `LIMIT`, not the whole bundle). Migration v35: `thread_deliveries`, and a one-time re-read (scan and body) of **bundled** mail from the last 45 days so parcels already on their way get a status; mail in no bundle is not touched, so the upgrade moves no thread into a bundle and reopens none. |
| Bridge (`crates/ffi/src/bundles.rs`) | `Engine::tracking_overview(utc_offset_minutes) -> [Parcel]`, records `Parcel`, `ParcelStatus`. `RustEngine` / `RustStoreReader.parcels()`, which makes a parcel only of a link `MailLink.url(_:host:)` accepts (http/https, no user or password, the URL's own host equal to the core's); `MockEngine.parcels()` over `parcelStore`, and a sample order in the sample inbox (`MockEngine.withSampleOrder`; `HEYPIGEON_MOCK_ORDER=0` runs the mock without it). |
| Shared shell (`ios-app/HeyPigeon`) | `ParcelItem`; `ListSnapshot.parcels`; `AppModel`: `parcels`, `inboxParcels`, `parcelFolds`, `parcelUpdates`, `listIsEmpty`, `openParcelDetails`, `openThread(id:)`, `dismiss(_:)`, `dismissAllParcels`, `markDone(_ fold)`, the two prefs (Track parcel is `Browser.open`, from the view: it changes no state); pure rules in `ParcelCard` (`visible`, `dismissing`, `statusLine`, `expected`, `updates`, `title`, `trackLabel`) and `MailLink`; the view `ParcelCardView` (`Features/Bundles/ParcelCard.swift`); the Settings toggle. |
| iPhone / iPad only | The card as the first section of `ThreadList`. |
| Mac only (`macos-app/HeyPigeonMac`) | The card as the first row of `InboxPage`'s list; palette entries. |

Syncs between devices: the two prefs, whole-value, last writer wins like
every pref (`inbox.dismissed_parcels`, `inbox.parcel_card`), through the
owner's Drive app data like the others (`DESIGN.md`, the sync table's
prefs row). A dismissal names its parcel by a 16-hex-digit digest of its
tracking or order number, or by its Gmail thread id (as muted threads
are named), with the time of the parcel's newest email. The number
itself is never written: a tracking number is enough to follow or
redirect a parcel, and a pref is readable by anything that can read the
Drive app data. (The digest hides the number from a reader; it is not
proof against someone who already holds a candidate number and checks
it.) Statuses, days, titles and links are derived from mail on each
device and never sync.
Leaves the device: the two prefs above, to the owner's own Drive — the
switch, and per dismissed parcel that digest or thread id and a time.
Nothing else, and nothing to Hey Pigeon, a carrier, a shop or a model.
The Track button opens the email's own link in the browser when the user
presses it — the same request the link in the email makes.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Surface | First section of the inbox list (`ThreadList`), over "All clear" when empty | The same list, in the same tabs | First row of the window's inbox list (`InboxPage`), over "All clear" when empty |
| Entry points | Tap: Track parcel, View details, …, +N more / Show less, X, Dismiss all. Long press on a row: the same menu | As iPhone; pointer and context menu | Click the same controls; right-click a row: the same menu. Palette (⌘K): "Track parcel · <title>" per parcel, "Dismiss all parcels" |
| Settings | Settings › Inbox › Show parcels | same | same (the Settings page) |
| Status | Implemented | Implemented | Implemented |

## Platform differences

- **Folding (R17) applies on iPhone and iPad only.** The Mac's inbox does
  not fold (`docs/bundles.md`: its keyboard selection walks threads), so
  there is no folded row to replace: every thread keeps its row, the
  status line has no "· N updates". Mark all done (R18) is in the Mac's
  menu too and does the same thing.
- **The Mac's card is outside the list's keyboard selection.** `j` / `k`
  walk threads; the card is reached with the pointer or the palette. No
  new bare key: a letter for one card is not worth a place in the map.
- **View details** opens the bundle as the Bundles cover on iPhone and
  iPad and as the Bundles page of the window on the Mac — where a bundle
  opens on each platform already.

## Acceptance criteria

- [x] R1, R2, R5–R7 — `parcels::tests::{links_of_one_number_are_one_parcel, a_track_link_alone_is_a_parcel_only_in_a_shopping_bundle, an_address_parsers_disagree_on_is_no_parcel, status_is_the_furthest_and_the_day_the_newest, parcels_leave_by_themselves, order_is_by_day_then_newest_then_delivered, archived_bundles_and_old_mail_have_no_parcels}` (core, against `MemStore`); `adapter-sqlite` `recent_bundle_threads_are_the_newest_within_the_window`
- [x] R3, R4, R8 — `parcels::tests::{json_ld_parcel_delivery, json_ld_order_with_delivery_and_graph, microdata_is_read_flat, microdata_title_survives_a_reach_that_ends_inside_a_letter, status_from_text, negations_are_not_a_status, days_from_text, implausible_days_are_dropped, hostile_markup_is_bounded}`; `bundles::tests::tracking_links_of_a_long_plain_text_return`; `adapter-gmail` `full_fetch_reads_delivery_markup_before_sanitizing`; `adapter-sqlite` `thread_deliveries_round_trip_and_go_with_the_thread`
- [x] R14's id (a digest, the same everywhere) — `parcels::tests::links_of_one_number_are_one_parcel`; migration v35 touches bundled mail only — `adapter-sqlite` `v35_upgrade_rereads_only_recent_bundled_mail`
- [x] Bridge — `ffi` `bundles::tests::tracking_overview_lists_a_bundles_parcel`; the generated Swift binding has `trackingOverview(utcOffsetMinutes:)`
- [ ] R9, R10, R12, R14, R16, R17 — `ParcelCardTests` (`ios-app/HeyPigeonTests/ParcelCardTests.swift`): written, run by `ios-ci` / `macos-ci`. R12's host on every form: `everyFormOfTheLineNamesTheHostItOpens`; the link check (R1 on the Swift side): `aLinkIsOfferedOnlyWhenItsHostIsTheOneNamed`; R16: `aReloadCarriesTheParcelsAndTheNextReadBringsTheNew`
- [ ] The card in the running app — `HeyPigeonUITests` `testTheSampleOrderShowsTheParcelCard` (`ios-ci`)
- [ ] Mac palette entries — `MacWindowTests` `ParcelPaletteTests`
- [x] Same wording on every platform: one shared view and one set of model methods
- [x] `MockEngine` covers `parcels()`
- [x] `rust-ci` equivalents green locally; [ ] `ios-ci`, `macos-ci` green on the PR
- [x] Guides updated (`docs/bundles.md`, `docs/ios.md`, `macos-app/CLAUDE.md`, `ios-app/CLAUDE.md`, `DESIGN.md`'s sync table)

## Open questions / assumptions

Assumed, matching how the app already behaves — say if any is wrong:

1. **The title is "Parcels"**, not "Happening soon": the card holds
   parcels only, and one fixed name does not change with what is known.
   Consequently the words are "Dismiss" / "Dismiss all" throughout.
2. **Parcels come from bundles only.** A shipping email in no bundle has
   no row (bundles are where tracking links are kept today).
3. **Folded mail goes under the card** (R17) rather than staying as a
   second row for the same bundle. It is never out of reach: the count is
   on the row, and the bundle lists it.
4. **The card stays over an empty inbox.** A parcel does not stop being
   on its way because its email was marked done.
5. **Text reading is deliberately narrow** (R3.2, R4): English, Czech,
   Slovak and German phrases, no weekday names, no US `month/day`. A row
   without markup and without such a phrase shows the link's host, the
   subject and the time.
6. **How common the markup is in the owner's mail is unknown** — it could
   not be measured from here. Without it a row still works (R12's last
   form); with it the row says what and when.
7. The grace periods (24 h, 3 days, 14 days), the cap (12) and the
   45-day window are first values.
8. **No carrier name on the card** (from the security review). The row
   says the link's host instead. A name could come back *beside* the
   host from a table of exact domains (`dhl.com`, `dhl.de`, `ups.com`,
   …) — which domains is the owner's call; the bundle's Info page still
   names its rows by the host's label (`BundleTracking.name`) and is
   outside this spec.
9. **IP-address links are not parcels**, and neither is a link with a
   backslash or non-ASCII before its path: a real carrier's page behind
   such an address would be missing from the card (its email and the
   bundle are unaffected).

## Verification

### After the security and performance reviews (2026-11-19, PR #157)

```
Spec: docs/specs/parcel-card.md   Verdict: Verified with notes

Rules           R1 ✓ parcels.rs host_of, number_id (an_address_parsers_disagree_on_is_no_parcel,
                links_of_one_number_are_one_parcel) · R8 ✓ clean_title, bundles.rs tracking_links
                (hostile_markup_is_bounded, tracking_links_of_a_long_plain_text_return) ·
                R3.1 ✓ microdata reach (microdata_title_survives_…) · v35 ✓ bundled mail only
                (v35_upgrade_rereads_only_recent_bundled_mail) · R12, R14–R16, R19 ✓
                ParcelCard.statusLine / trackLabel, MailLink, AppModel.reload — Swift read,
                not compiled
Parity          iPhone ✓ · iPad ✓ · Mac ✓ — one view, one status line (the palette's second
                line is the same function), one link check in RustEngine for the card and
                for both Info pages
Layering        ✓ what a host is: core (host_of) and one Swift check where a string becomes
                a URL (MailLink, in the engine adapter, not in a view) · the limited thread
                read is a port method with a default, SQLite and the fake
Tests / CI      rust ✓ (cargo fmt --check, the rust-ci cargo test, Swift bindgen: ran locally) ·
                ios-ci not seen green on this change · macos-ci not seen green on this change
Not checked     Nothing Swift was compiled. What Foundation's URL(string:) makes of each
                backslash form is asserted in aLinkIsOfferedOnlyWhenItsHostIsTheOneNamed and
                has only been run by CI, if at all. The new UI test. The line's length on a
                small phone now that it carries a host.
Drift / fixes   Left, for the owner: the Info page still names a row by the host's label or
                the sender (BundleTracking.name, macOS BundleInfo.name) — the card no longer
                does (assumption 8); and its grouping is still the Swift copy noted below.
```

### First pass

Architect, 2026-11-19, on the branch before its PR.

```
Spec: docs/specs/parcel-card.md   Verdict: Verified with notes

Rules           R1–R8 ✓ crates/core/src/parcels.rs (overview, from_markup, from_text; the tests
                named above, run) · R3.1 ✓ adapter-gmail full_fetch (before sanitize::html) ·
                R9, R14–R18 ✓ AppModel (cardParcels, regroup, dismissParcels, group underParcels)
                · R10–R13, R19 ✓ Features/Bundles/ParcelCard.swift — Swift read, not compiled
Parity          iPhone ✓ · iPad ✓ (the same ThreadList; no key) · Mac ✓ (the same view and
                model methods; differences as listed: no fold, outside the cursor, palette)
Layering        ✓ what a parcel is and says: core · one Engine call, MockEngine twin ·
                rules in ParcelCard / AppModel statics · no store read in a view · no bare #if
Tests / CI      rust ✓ (cargo fmt --check, the rust-ci cargo test, Swift bindgen: ran locally) ·
                ios-ci not run · macos-ci not run
Not checked     Nothing Swift was compiled or seen on a device: layout, the glass pill in a
                list row, the menu's section title, VoiceOver order, Dynamic Type, dark mode.
                How often real mail carries the markup. The 45-day re-read (v35) on a real
                mailbox.
Drift / fixes   Fixed in passing: tracking_links sliced the body at positions found in a
                to_lowercase() copy (wrong slice or a panic after "İ"). Left, for the owner:
                the Info page groups shipments with its own Swift copy of the rule
                (BundleTracking.shipments), which does not fold an email's number-less link
                into its numbered one as the card's core rule does — it can show one row
                more than the card; and the redirect-host list now exists in both.
```
