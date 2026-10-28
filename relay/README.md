# Hey Pigeon push relay (optional, iOS only)

The one server component Hey Pigeon has, and it is optional: without it the
iOS app still syncs on launch, on foreground, on pull and from background
refresh. With it, the phone learns about new mail within seconds and keeps an
accurate badge. Everything runs in the same Google Cloud project as the OAuth
client and is created by Terraform ([../terraform/README.md](../terraform/README.md)).

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
token. It is authenticated with the Google access token the app already holds
(`oauth2.googleapis.com/tokeninfo` → email), so there is no new login and a
mailbox's tokens can only be written by its owner. It answers with the
Pub/Sub topic to `watch`, so the app needs exactly one setting: the relay URL.

## What the relay sees and stores

| | |
| --- | --- |
| Stored | `sha256(email) → [{ deviceToken, environment, platform, updatedAt }]` — the address itself is not stored |
| Seen per event | `emailAddress` + `historyId` (a counter), from Gmail |
| Sent to the phone | that same email + historyId, inside a silent push; the phone fetches from Gmail directly and composes the notification locally |
| Logged | hash prefix + APNs status. Never addresses, payloads, subjects or OAuth tokens |

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
src/apns.js       ES256 provider JWT (node:crypto, 50-min cache), HTTP/2 to api[.sandbox].push.apple.com
src/tokens.js     Firestore token table
src/auth.js       tokeninfo check: aud ∈ GOOGLE_CLIENT_IDS, email verified, gmail scope present
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
`GOOGLE_CLIENT_IDS` (iOS OAuth client ids, comma-separated), `PUBSUB_TOPIC`.

APNs behaviour: `apns-push-type: background`, `apns-priority: 5`,
`apns-collapse-id` derived from the email hash (a burst collapses into one
wake), `apns-expiration` 10 minutes (a stale wake is useless). A `410` deletes
the device token; a `400 BadDeviceToken` is kept (almost always a token on the
other APNs host) and logged.

## Deploying

Terraform does it, including the code: `terraform apply` zips this folder,
uploads it and deploys both functions; a code change is a new zip hash, so the
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
- Server side: `terraform destroy` in `terraform/` (the Firestore database is
  protected and left in place; delete it by hand if you want it gone), then in
  `terraform/bootstrap/`. Any lease still running expires within 7 days.

## Known limits

- iOS throttles silent pushes (a few per hour under battery pressure) and
  drops them in Low Power Mode. Mail still appears on open; only the
  notification lags.
- One topic serves all accounts; the address in the message routes to the
  right tokens.
