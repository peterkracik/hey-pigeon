# Parcel card

Status: Implemented — not yet verified on a device (see Verification)
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
  the button only ever opens a link that is visible in the email.

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
  click-redirect's. A link that names a user before its host
  (`https://dhl.com@evil.example/`) is never a parcel's link. The same
  number in two bundles is one parcel, the first bundle's.
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
  characters with control characters removed, and no value from markup
  is ever used as an address. A parse that fails yields nothing.

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
  delivery"; "Expected today / tomorrow / yesterday / Friday / 24 Nov";
  else the carrier or shop (`BundleTracking.name`, the email's sender for
  a redirect), "Shipped" when that is known, else the email's subject,
  and the email's time. A parcel that holds folded mail (R17) ends with
  "· N updates".
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
  entries "id@time"; an id is the parcel's number or its email's Gmail
  thread id, the same on every device). Entries older than 180 days are
  dropped when the list is next written.
- R15. Settings › Inbox › **Show parcels** (`inbox.parcel_card`, synced,
  unset = on): "Parcels on their way get a card at the top of your inbox.
  Worked out on this \(Device.name) from your mail; Track parcel opens
  the email's own link in your browser." Off, the reload does not ask
  the store for parcels.
- R16. The items come with the list's reload (one engine call,
  `tracking_overview`, read off the main thread into the list snapshot);
  no view asks the store. A parcel's link is known once its email's text
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
  Track parcel is also a button of its own, named with the carrier
  ("Track parcel with DHL"); targets are 44 pt on touch; at accessibility
  text sizes the buttons stand under each other; a status is words, never
  a colour alone; the expand and collapse honour Reduce Motion.

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core (`crates/core/src/parcels.rs`) | `Delivery`, `ParcelStatus`; `from_markup` (JSON-LD, microdata), `from_text`; `remember_deliveries` (after a full fetch) and the text pass in `bundles::link_pass`; `overview` (R1–R7). `Message.delivery` carries what the Gmail adapter read before sanitizing (`adapter-gmail` `full_fetch`), as `open_token` does. Port: `Store::set_thread_deliveries`, `thread_deliveries` (default impls; `MemStore`, SQLite). Migration v35: `thread_deliveries`, and a one-time re-read of bundled mail from the last 45 days so parcels already on their way get a status. |
| Bridge (`crates/ffi/src/bundles.rs`) | `Engine::tracking_overview(utc_offset_minutes) -> [Parcel]`, records `Parcel`, `ParcelStatus`. `RustEngine` / `RustStoreReader.parcels()`; `MockEngine.parcels()` over `parcelStore`, and a sample order in the sample inbox (`MockEngine.withSampleOrder`). |
| Shared shell (`ios-app/HeyPigeon`) | `ParcelItem`; `ListSnapshot.parcels`; `AppModel`: `parcels`, `inboxParcels`, `showsParcelCard`, `parcelFolds`, `track`, `openParcelDetails`, `openParcelEmail`, `dismiss(_:)`, `dismissAllParcels`, `markDone(_ fold)`, the two prefs; pure rules in `ParcelCard` (`visible`, `statusLine`, `dismissing`, `pruned`, `absorbed`); the view `ParcelCardView` (`Features/Bundles/ParcelCard.swift`); the Settings toggle. |
| iPhone / iPad only | The card as the first section of `ThreadList`. |
| Mac only (`macos-app/HeyPigeonMac`) | The card as the first row of `InboxPage`'s list; palette entries. |

Syncs between devices: the two prefs, whole-value, last writer wins like
every pref (`inbox.dismissed_parcels`, `inbox.parcel_card`), through the
owner's Drive app data like the others. A dismissal names its parcel by
tracking or order number, or by Gmail thread id — the first identifiers
from mail in a pref besides muted thread ids and blocked addresses.
Statuses, days, titles and links are derived from mail on each device and
never sync.
Leaves the device: nothing. The Track button opens the email's own link
in the browser when the user presses it — the same request the link in
the email makes.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Surface | First section of the inbox list (`ThreadList`), over "All clear" when empty | The same list, in the tabs and in the split layout's list column | First row of the window's inbox list (`InboxPage`), over "All clear" when empty |
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

- [x] R1, R2, R5–R7 — `parcels::tests::{links_of_one_number_are_one_parcel, a_track_link_alone_is_a_parcel_only_in_a_shopping_bundle, status_is_the_furthest_and_the_day_the_newest, parcels_leave_by_themselves, order_is_by_day_then_newest_then_delivered, archived_bundles_and_old_mail_have_no_parcels}` (core, against `MemStore`)
- [x] R3, R4, R8 — `parcels::tests::{json_ld_parcel_delivery, json_ld_order_with_delivery_and_graph, microdata_is_read_flat, status_from_text, negations_are_not_a_status, days_from_text, implausible_days_are_dropped, hostile_markup_is_bounded}`; `adapter-gmail` `full_fetch_reads_delivery_markup_before_sanitizing`; `adapter-sqlite` `thread_deliveries_round_trip_and_go_with_the_thread`
- [x] Bridge — `ffi` `bundles::tests::tracking_overview_lists_a_bundles_parcel`; the generated Swift binding has `trackingOverview(utcOffsetMinutes:)`
- [ ] R9, R10, R12, R14, R17 — `ParcelCardTests` (`ios-app/HeyPigeonTests/ParcelCardTests.swift`): written, run by `ios-ci` / `macos-ci`
- [ ] Mac palette entries — `MacWindowTests` `ParcelPaletteTests`
- [x] Same wording on every platform: one shared view and one set of model methods
- [x] `MockEngine` covers `parcels()`
- [x] `rust-ci` equivalents green locally; [ ] `ios-ci`, `macos-ci` green on the PR
- [x] Guides updated (`docs/bundles.md`, `docs/ios.md`, `macos-app/CLAUDE.md`, `ios-app/CLAUDE.md`)

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
   without markup and without such a phrase shows the carrier, the
   subject and the time.
6. **How common the markup is in the owner's mail is unknown** — it could
   not be measured from here. Without it a row still works (R12's last
   form); with it the row says what and when.
7. The grace periods (24 h, 3 days, 14 days), the cap (12) and the
   45-day window are first values.

## Verification

See the end of the file once verified; the architect's last report is
kept here.
