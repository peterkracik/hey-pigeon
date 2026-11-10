# Reply recipients

Status: Implemented — #119, #120, and the follow-up that added R6–R8
Related: `docs/ios.md` (Reply pill, Compose and reply), `DESIGN.md`

## What and why

Who a reply goes to, and from which address. A reply to a list or a
booking system used to go to its no-reply sender; Reply all copied the
user on their own "Send mail as" address. One builder decides, for every
way into a reply, so the same message gives the same recipients
everywhere.

**Out of scope:** `Mail-Followup-To` and list headers; choosing between
several Reply-To addresses (all are used).

## Behaviour

- R1. A reply to someone else's message goes to its Reply-To addresses
  when the sender set any that are not the user's own; otherwise to its
  sender.
- R2. Reply all adds everyone else on To and Cc, each once, compared
  without case; neither the reply's To addresses nor the sender are
  repeated.
- R3. A reply to the user's own message goes where that message went
  (Reply all: its Cc too). Its Reply-To is ignored.
- R4. The account's address ("me") and its "Send mail as" aliases are
  the user's own: never a recipient, and a message sent from an alias is
  the user's own (R3).
- R5. Aliases are asked of Gmail when the accounts load, once per account
  and launch, and kept on the device between launches, so a reply started
  offline or at launch knows them. Removing an account forgets its
  aliases.
- R6. A reply to mail that came to an alias is sent from that alias; a
  reply to the user's own alias-sent message is sent from it again. Any
  other reply is sent from the account's address. The composer's From
  shows the choice and can change it.
- R7. A message whose replies go elsewhere than its sender says so in its
  open header: "replies go to …", under the recipients.
- R8. A reply redirected by Reply-To shows the address itself in the
  composer, never a name the thread knows for it: the sender chose both.
  On the Mac its recipient fields open instead of staying folded behind
  the "Draft to …" line.
- R9. The Reply pill's default is Reply all exactly when Reply all would
  copy someone (R2, R4).
- R10. Mail stored before the Reply-To header was kept gets it when its
  thread is next fetched in full; migration v27 asks for that fetch once
  per opened thread.

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core (`desktop-app/crates/core`, adapters) | `Message.reply_to_addrs`; SQLite v27; `Reply-To` in the Gmail metadata headers |
| Bridge (`crates/ffi`, `RustEngine`, `MockEngine`) | `MailMessage.reply_to_addrs` → `MessageItem.replyTo` |
| Shared shell (`ios-app/HeyPigeon`) | `SendDraft.reply` (R1–R4, R6), `MessageItem.repliesGoTo` (R7), `SendDraft.repliesElsewhere` (R8), `AppModel.ownAddresses` / `loadSendAliases` (R5), `ThreadView.defaultReply` (R9), the header line in `ThreadView`'s message row |
| iPhone / iPad only | — |
| Mac only (`macos-app/HeyPigeonMac`) | the composer's fields open for R8 (`ComposeView`, Mac extension) |

Syncs between devices: no. Each device asks Gmail for the aliases itself.
Leaves the device: nothing new. The aliases are read from Gmail and kept
in the app's preferences on the device.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Surface | thread view, composer sheet | same | thread page, inline composer or window |
| Entry points | Reply pill, message menu, banner's Reply, Siri and Shortcuts | same | `r` / `a`, Reply pill, message menu, banner's Reply, Siri and Shortcuts |
| Settings | none | none | none |
| Status | Implemented | Implemented | Implemented |

## Platform differences

- R8: the phone's composer always shows its To field, so there is nothing
  to open; the Mac folds a reply's fields and opens them for a redirected
  reply.

## Acceptance criteria

- [x] R1–R4, R6–R8 — `replyGoesToTheSenderAndReplyAllCopiesTheRest`,
  `replyGoesWhereTheSenderAskedAndNeverToTheUsersOwnAlias` (`ModelTests`)
- [x] R10 — `v27_upgrade_refetches_opened_mail_for_its_reply_to`
  (`adapter-sqlite`)
- [ ] R5, R9 — no test; read from the code
- [x] Same wording on every platform ("replies go to …")
- [x] `rust-ci`, `ios-ci`, `macos-ci` green
- [x] Guides updated (`docs/ios.md`)

## Open questions / assumptions

- Several Reply-To addresses all become recipients; no client-side choice.
- A Reply-To equal to the sender changes nothing and is not announced.

## Verification

Not yet verified on a device. Tests and CI only.
