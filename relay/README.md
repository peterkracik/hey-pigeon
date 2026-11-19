# Hey Pigeon relay (optional)

The one server component Hey Pigeon has, and it is optional. It has two
halves, three small functions in all:

- **Push** (iOS): without it the iOS app still syncs on launch, on
  foreground, on pull and from background refresh. With it, the phone learns
  about new mail within seconds and keeps an accurate badge.
- **Read status** (`opens`): the server half of "was my message opened"
  ([../docs/specs/read-status.md](../docs/specs/read-status.md)). Used only
  for a mailbox whose owner turned read status on in the app (Settings →
  Accounts; off by default, per account): the app then registers a token
  for each message it sends from that account and puts the pixel in it.
  For every other mailbox the apps do not call it — except once to delete:
  an account whose read status was just turned off, or that is being
  removed, sends `DELETE /v1/tokens`, repeated until the relay answers.

Everything runs in the same Google Cloud project as the OAuth client and is
created by Terraform ([../terraform/README.md](../terraform/README.md)).

```text
Gmail users.watch ──► Pub/Sub topic `gmail-push` ──► Cloud Run function `on-mail-change`
   (per account,            {emailAddress,                 (Pub/Sub trigger, no public URL)
    renewed daily            historyId}                           │
    by the app)                                                   ├─ Firestore  tokens/{sha256(email)} → [device tokens]
                                                                  ├─ Secret Manager  apns-key (.p8, read at runtime)
                                                                  └─ APNs  silent push {content-available: 1, email, historyId}
                                                                                │
                                                        iPhone wakes ◄──────────┘
                                                          → delta sync from Gmail (Rust core, as always)
                                                          → local notification per new thread, badge = unread
```

A second function, `register-token`, lets the app store its APNs device
token. It is authenticated with the Google access token the app already holds:
`tokeninfo` proves the token was issued to the app's OAuth client and carries a
Gmail scope, and Gmail's `users/me/profile` names the mailbox (the app's grant
has no `userinfo.email` scope, so `tokeninfo` alone cannot). No new login, and
a mailbox's tokens can only be written by its owner. It answers with the
Pub/Sub topic to `watch` and the URL of the `opens` function
(`{ topic, opensUrl }`), so the app needs exactly one setting: the relay URL.
A `GET` with the same token answers the same and writes nothing — for a
device that has no APNs token to register and only needs the two addresses.

## Read status: the `opens` function

```text
app, about to send ──► POST /v1/tokens {token}      (Google access token)
                          └─ Firestore  opens/{token} → { mailboxHash, createdAt, expiresAt, events: [] }
                             answers { pixelUrl }

recipient's mail app ─► GET /o/<token>.gif          (public, no auth)
                          ├─ always: a 1×1 GIF, 200, no-store, no redirect, no cookie
                          ├─ unknown / expired / malformed token: nothing else — one lookup, no write, no log
                          └─ known token: classify the fetch in memory → record { label, at } (at most 25 per label)

app, on sync ─────────► POST /v1/opens {tokens}     (Google access token) → { token: [{label, at}] }, own mailbox only
app, switch turned off ► DELETE /v1/tokens          (Google access token) → every document of that mailbox, 204
```

A token is 128 random bits the app makes. It is in the HTML every recipient
receives, so holding one proves nothing: query and delete are bound to the
caller's mailbox, and another mailbox's token is left out of an answer
exactly like an unknown one.

**How a fetch is labelled** (`src/classify.js`, pure; the source address and
user agent are read for this and passed to nothing else):

| Fetch | Label |
| --- | --- |
| Gmail's image proxy (`GoogleImageProxy`) | `opened` |
| A mail client or browser asking directly | `opened` |
| Apple's mail privacy proxy: the source address is in Apple's published egress ranges, or the user agent is the bare `Mozilla/5.0` that proxy sends | `hidden` — delivered to a device that hides opens; never shown as opened |
| Within 2 minutes of registration; a `HEAD`; no user agent; a scanner, gateway or script | not stored |

**Apple's egress ranges** (`src/ranges.js`) are fetched from
`mask-api.icloud.com/egress-ip-ranges.csv` once per instance, on the first
request for a *known* token, and kept in memory. Fetched rather than
bundled: the list is large and changes weekly, and a stale copy would turn
Apple's proxy into "opened" without anyone noticing. If it cannot be loaded
(4 s timeout, an error, an answer with no ranges) the instance logs
`opens: apple ranges unavailable … — classifying by user agent`, labels by
user agent alone and tries again after five minutes. In that mode Apple's
proxy is still `hidden` (its bare user agent), and `opened` is only given
to a fetch that names a real mail client or browser, which the proxy never
does. What is lost while the list is down: a browser behind iCloud Private
Relay counts as `opened` where it would have been `hidden`.

**What is kept of repeated fetches.** The same label within a minute of its
last event adds nothing (a mail client asking three times while it renders
is one open, and a loop costs one write a minute at most). Each label keeps
at most 25 events: the first 24 and, from then on, always the latest. One
label cannot use the other's room, so a recipient who fills `hidden` cannot
push out a later real `opened`.

**Limits.** A mailbox may hold 20,000 live tokens (Gmail's 500 recipients a
day for 30 days, every message tracked, is 15,000); the next registration
answers 429. A token never changes hands: registering one that exists under
another mailbox answers 409, expired or not. Until the pixel has its own
domain (`OPENS_PUBLIC_URL`), registration answers 503 and stores nothing —
no message is ever sent pointing at a run.app address. A failing store
answers 503 `{ "error": "unavailable" }` on the app's routes and logs the
error's code; the pixel route still answers the GIF.

**The framework's own logging, and how to see it is gone.** Express and its
body parser reject a request they cannot parse without calling the handler,
and print the error: `URIError: Failed to decode param 'o/%E0%A4%A.gif'`
for a path with a broken escape, `SyntaxError: … "{\"token\":\"…" is not
valid JSON` for a body. On an instance serving `opens`, `index.js` replaces
`console.error` and `console.warn` so that only the class name is printed
(`test/quiet.test.js`). To reproduce, with no cloud access:

```sh
npx functions-framework --target=opens --signature-type=http --port=8793 2>err.log &
curl -s -o /dev/null 'http://127.0.0.1:8793/o/%E0%A4%A.gif'
curl -s -o /dev/null -X POST -H 'content-type: application/json' -d '{"token":"0123' http://127.0.0.1:8793/v1/tokens
cat err.log   # opens: output withheld (URIError) / (SyntaxError) — no path, no body
```

Not covered: something that writes to `process.stderr` directly instead of
through `console` (Node's own process warnings do; they carry nothing of a
request), and the two answers above still go to the caller as Express's
HTML 400, which names the error to the one who sent it.

**Not built yet:** telling the phone about an open. The handler has the seam
(`onOpen(mailboxHash)`), `index.js` wires nothing to it, and the function
holds no APNs configuration.

## What the relay sees and stores

Push (`on-mail-change`, `register-token`):

| | |
| --- | --- |
| Stored | `sha256(email) → [{ deviceToken, environment, platform, updatedAt }]` — the address itself is not stored |
| Seen per event | `emailAddress` + `historyId` (a counter), from Gmail |
| Sent to the phone | that same email + historyId, inside a silent push; the phone fetches from Gmail directly and composes the notification locally |
| Logged | hash prefix + APNs status. Never addresses, payloads, subjects or OAuth tokens. Cloud Run's own request log of `register-token` is kept (caller IP, user agent, URL — the app's requests only) |

Read status (`opens`):

| | |
| --- | --- |
| Stored | Per tracked message: `opens/{token} → { mailboxHash: sha256(email), createdAt, expiresAt, events: [{ label: opened \| hidden, at }] }`, at most 25 events per label. A mailbox holds at most 20,000 live tokens. Not the address, not the message, its subject, its recipients or its Gmail id |
| Kept for | 30 days from registration (Firestore TTL on `expiresAt`, which can lag by about a day; the function itself treats an expired document as absent), or until the mailbox's owner calls delete |
| Seen per pixel request, not kept | The fetching client's IP address and user agent, for the length of the request, to choose the label. Passed to nothing: not Firestore, not a log line |
| Seen per app request | The Google access token (verified at Google, not stored) and the tokens named |
| Sent to Apple | One download of the public egress list per instance. Nothing about any request |
| Logged by the function | Its own lines: `opens <hash prefix> registered`, `… deleted <n>`, `… at its token limit`, the state of the Apple list, and a failed store call's error code. Never a token, an address, a user agent, a URL or a request body; a pixel request that goes well writes no line. Anything a library prints on the instance is reduced to the error's class name — `opens: output withheld (URIError)` — because the framework rejects an unparseable request before the handler runs and would otherwise print its path or a piece of its body (`src/quiet.js`; reproduction below) |
| Logged by Cloud Run | Its request log (IP, user agent, URL per request) is written by the platform and dropped before it is stored: a project log exclusion that Terraform creates before the function (`terraform/logging.tf`) keeps it out of the project's log storage. A log sink someone adds to the project by hand would still receive it — there is none in this repository |

Anyone can ask for any pixel URL; an unknown token costs one document read
and is otherwise a no-op. Anyone with a Google account who signs in through
the app's OAuth client can register tokens for their own mailbox.

Anyone who learns the topic name can `users.watch` their own mailbox into it;
an address without registered devices is a silent no-op.

## Corrections to the original issue text (#16)

- `users.watch` needs **no Pub/Sub OAuth scope** on the user's grant. The
  `gmail.modify` scope the app already requests is enough; what matters is
  that `gmail-api-push@system.gserviceaccount.com` may publish to the topic
  (Terraform grants it). Nothing is added to the consent screen.
- The APNs environment is **per device token**: an Xcode build registers a
  `sandbox` token, a TestFlight / App Store build a `production` one. The
  relay routes each token to the right APNs host. `apns_env` is not a
  deploy-time setting.
- A watch is renewed whenever **less than 6 days** of its 7-day lease remain,
  i.e. once a day on any day the app syncs (Google recommends daily renewal).
  A phone that does not open the app for a week loses push until the next open.
- The runtime is **Node 22** (Node 20 reached end of life in April 2026).

## Code

```text
index.js          Cloud Run functions entry: wires Firestore, Secret Manager, APNs, env into the handlers
src/handlers.js   onMailChange + registerToken, pure (all I/O injected) — the privacy rules live here
src/opens-handlers.js  the opens function's four routes, pure — read status's privacy rules live here
src/classify.js   a fetch of the pixel → opened | hidden | ignored, pure
src/ranges.js     Apple's egress ranges: fetch once per instance, parse, search; null when unavailable
src/opens.js      Firestore opens table
src/apns.js       ES256 provider JWT (node:crypto, 50-min cache), HTTP/2 to api[.sandbox].push.apple.com
src/tokens.js     Firestore token table
src/auth.js       tokeninfo check (aud ∈ GOOGLE_CLIENT_IDS, gmail scope), then Gmail users/me/profile for the address
src/secret.js     reads the .p8 from Secret Manager at runtime
test/             node --test, no network
```

```sh
npm ci && npm test
# run one function locally against fakes:
GOOGLE_CLIENT_IDS=x PUBSUB_TOPIC=projects/p/topics/gmail-push npm run start:register
```

Environment (set by Terraform): `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`
(= `app.heypigeon.ios`), `APNS_SECRET_NAME` (`projects/<p>/secrets/apns-key`),
`GOOGLE_CLIENT_IDS` (the OAuth client ids whose tokens are accepted,
comma-separated: the iOS client, and the Mac's when it has its own),
`PUBSUB_TOPIC`,
`OPENS_URL` (on `register-token`: what it reports as `opensUrl`; the pixel's
custom domain, empty until it is mapped). The `opens`
function gets `GOOGLE_CLIENT_IDS` and `OPENS_PUBLIC_URL` (the pixel's custom
domain, and the only address registration ever hands out; while it is empty
`POST /v1/tokens` answers 503 and stores nothing).

APNs behaviour: `apns-push-type: background`, `apns-priority: 5`,
`apns-collapse-id` derived from the email hash (a burst collapses into one
wake), `apns-expiration` 10 minutes (a stale wake is useless). A `410` deletes
the device token; a `400 BadDeviceToken` is kept (almost always a token on the
other APNs host) and logged.

## Deploying

Terraform does it, including the code: `terraform apply` zips this folder,
uploads it and deploys the three functions; a code change is a new zip hash, so the
next apply rolls a new revision. CI runs `plan` on pull requests and `apply`
on `main` for changes under `relay/` or `terraform/`
(`.github/workflows/deploy-relay.yml`). Details, first-time setup and the
manual prerequisites: [../terraform/README.md](../terraform/README.md).

## Rotating the APNs key

1. Apple Developer → Keys → new APNs key; download the `.p8`, note the Key ID.
2. `gcloud secrets versions add apns-key --data-file=AuthKey_<KEYID>.p8`
3. Set the new Key ID in the Terraform variables (`apns_key_id`) and apply —
   the env change rolls new revisions, which read `latest` on first use.
4. Revoke the old key in the developer portal.

## Turning it off

- In the app: Settings → Notifications → "New mail (push)" off. The phone
  DELETEs its token and the engine calls `users.stop` for every account.
- Read status, in the app: Settings → Accounts → the account → "Read
  status" off. The device stops adding pixels and asking about opens at
  once and sends `DELETE /v1/tokens` right away, then again on every sync
  round until the relay has answered. The user's other devices learn
  "off" when they next sync; one that had not heard yet may still send a
  tracked message in between, and when it then learns "off" it sends the
  delete itself, so that token goes too. A device that sent nothing after
  the decision sends no delete. Pixels already sent then name unknown
  tokens.
- Removing an account from a device sends the same delete first (one
  attempt, a few seconds at most) when read status is on for it or a
  delete is still waiting. The delete is per mailbox: other devices that
  still have the account lose their records too and are not told.
- What can leave records behind: the account is removed, or signed out
  (the delete needs its Google token), before the relay could be reached.
  Nothing deletes them then; they expire 30 days after each message was
  registered.
- Server side: `terraform destroy` in `terraform/` (the Firestore database is
  protected and left in place; delete it by hand if you want it gone), then in
  `terraform/bootstrap/`. Any lease still running expires within 7 days.

## Known limits

- iOS throttles silent pushes (a few per hour under battery pressure) and
  drops them in Low Power Mode. Mail still appears on open; only the
  notification lags.
- One topic serves all accounts; the address in the message routes to the
  right tokens.
- Read status counts a fetch, not a person: the sender opening their own
  Sent mail in Gmail on the web counts as an open, a recipient who blocks
  remote images never does, and Apple Mail's privacy proxy only ever says
  "hidden".
- A token from an OAuth client that is not in `GOOGLE_CLIENT_IDS` is
  refused by `register-token` and `opens` alike. The Mac app's client gets
  there through `google_mac_client_id` (Terraform) /
  `HEYPIGEON_MAC_OAUTH_CLIENT_ID` on the `infra` environment; until that
  value is set, a Mac built with its own client is refused.
- The memory of `opens` (512M) has not been measured on the deployed
  function. A synthetic 300,000-line list parsed at about 237 MB locally,
  so 256M would not do.
- A fetch through Apple's proxy and one from a mail client within the same
  minute are both recorded; two with the same label within a minute are
  one.
