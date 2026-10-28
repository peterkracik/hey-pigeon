# Google Cloud for the push relay — Terraform

Everything the optional iOS push relay ([../relay/README.md](../relay/README.md))
needs in Google Cloud is created here. Nothing is clicked together in the
console except the three things Terraform has no resource for (below).

Two stacks, on purpose:

| Stack | Who applies | What it owns |
| --- | --- | --- |
| `bootstrap/` | you, from a laptop, rarely | APIs, the Terraform state bucket, the three service accounts and their **project-level** IAM, Workload Identity Federation for GitHub Actions |
| `.` (root) | CI on `main` (and you, the first time) | Pub/Sub topic, Firestore database, the empty APNs secret, Artifact Registry repo, source bucket, the two Cloud Run functions **and their code**, resource-level IAM |

The split keeps the CI identity unable to grant itself anything: it can
deploy functions, topics and secrets, but it has no project IAM, service
account admin or WIF rights.

## What gets created

- **APIs**: Pub/Sub, Cloud Run, Cloud Functions, Cloud Build, Artifact
  Registry, Eventarc, Firestore, Secret Manager, IAM, IAM Credentials, STS,
  Resource Manager, Logging.
- **Service accounts**: `relay-fn` (function runtime + Eventarc trigger
  identity: Firestore user, event receiver, reads the APNs secret),
  `relay-build` (Cloud Build), `relay-deployer` (CI).
- **Workload Identity Federation**: pool `github`, provider `github-oidc`
  limited to `assertion.repository == "<github_repository>"`, bound to
  `relay-deployer`.
- **Pub/Sub topic** `gmail-push`, publishable by
  `gmail-api-push@system.gserviceaccount.com`.
- **Firestore** `(default)`, Native mode, delete protection on.
- **Secret Manager** secret `apns-key` — empty; you upload the `.p8`.
- **Artifact Registry** Docker repo `relay` (keep last 5 images, delete after 30 days).
- **GCS**: `<project>-tfstate` (versioned) and `<project>-relay-src`.
- **Cloud Run functions** (2nd gen, Node 22): `on-mail-change` (Pub/Sub
  trigger, internal ingress only) and `register-token` (public HTTPS,
  authenticated by the caller's Google access token).

Cost at personal volume: $0 — every service above has a free tier that a
few hundred pushes a day does not approach.

## Manual prerequisites

1. A Google Cloud project **with billing attached** (Cloud Run / Eventarc /
   Secret Manager refuse to enable without it). Use the project that holds
   the OAuth clients ([../docs/google-oauth-setup.md](../docs/google-oauth-setup.md)).
2. The **iOS OAuth client** (type iOS, bundle id `app.heypigeon.ios`) in that
   project — its client id is `google_client_ids`. No new scopes: `users.watch`
   works with the `gmail.modify` the app already asks for.
3. **Apple**: an APNs auth key (Developer → Keys → Apple Push Notifications
   service): the `.p8` file, its Key ID, and your Team ID. The Push
   Notifications capability on the App ID `app.heypigeon.ios` is enabled by
   the `publish-ios` workflow through the App Store Connect key; for local
   device builds enable it once under developer.apple.com → Identifiers.
4. Locally: `terraform` ≥ 1.9, `gcloud`, and
   `gcloud auth application-default login` as a project owner.

## First apply (once, from a laptop)

```sh
# 1. Bootstrap: APIs, state bucket, service accounts, WIF (local state)
cd terraform/bootstrap
terraform init
terraform apply -var project_id=<PROJECT_ID>

# 2. Park the bootstrap state in the bucket it just created
#    (uncomment `backend "gcs" {}` in versions.tf first)
terraform init -migrate-state \
  -backend-config="bucket=$(terraform output -raw state_bucket)" \
  -backend-config="prefix=bootstrap"

# 3. Root stack
cd ..
cp backend.hcl.example backend.hcl        # bucket = the state_bucket output
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform apply

# 4. The APNs key — the only secret, and it never touches Terraform
gcloud secrets versions add apns-key --data-file=AuthKey_<KEYID>.p8 --project <PROJECT_ID>

# 5. The relay URL for the app
terraform output register_token_url
```

If the project already had a `(default)` Firestore database, import it before
step 3's apply: `terraform import google_firestore_database.default "(default)"`.

The 60-second `time_sleep` in `functions.tf` exists for this first apply: IAM
bindings take a moment to propagate and the function create would otherwise
race them.

## CI (`.github/workflows/deploy-relay.yml`)

Pull requests touching `relay/**` or `terraform/**` run the relay tests,
`terraform fmt -check`, `validate` and `plan` (the plan is posted as a PR
comment). Pushes to `main` run `apply`. Auth is Workload Identity Federation —
no key file anywhere.

Set these **repository variables** (Settings → Secrets and variables → Actions
→ Variables; none are secret):

| Variable | Value |
| --- | --- |
| `GCP_PROJECT_ID` | the project id |
| `TF_STATE_BUCKET` | bootstrap output `state_bucket` |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | bootstrap output `workload_identity_provider` |
| `GCP_DEPLOYER_SA` | bootstrap output `deployer_sa_email` |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | from Apple |
| `HEYPIGEON_IOS_OAUTH_CLIENT_ID` | the iOS OAuth client id |

Everything else about the deploy (region, runtime, topic name) is in the
Terraform files.

## Day-to-day

- **Change the relay code**: edit `relay/`, open a PR, merge. `terraform apply`
  on `main` zips the folder, uploads it under its hash and rolls new revisions.
- **Rotate the APNs key**: `gcloud secrets versions add apns-key --data-file=…`,
  change `APNS_KEY_ID`, apply. The functions read `latest` on their first push
  after a cold start.
- **Change bootstrap** (new role, another repository): `terraform apply` in
  `bootstrap/` from a laptop.
- **Turn it all off**: `terraform destroy` here (the Firestore database is
  protected and stays; `gcloud firestore databases delete` if you want it
  gone), then in `bootstrap/`. Leases running on phones expire within 7 days;
  the app's toggle calls `users.stop` immediately.

## Why some things are the way they are

- The APNs key is **read at runtime** rather than mounted as a secret env
  var because a Cloud Run deploy fails when the mounted secret has no
  version yet, and the key is uploaded after the first apply by design.
- `register-token` is **public at the Cloud Run level** (`allUsers` invoker)
  because its authentication is the caller's Google access token, verified
  against Google's `tokeninfo`; there is no identity Cloud Run could check.
- The **Eventarc trigger** runs as `relay-fn`, which must hold
  `roles/run.invoker` on `on-mail-change` and `roles/eventarc.eventReceiver`
  — both granted here and in bootstrap. Eventarc creates the push
  subscription itself; no Terraform `google_pubsub_subscription`.
- The **build** uses its own `relay-build` account instead of the Compute
  Engine default, which newer projects may not have (or not with Editor).
- The deployer is **not** `roles/editor`: Editor cannot manage IAM anyway,
  and it is far broader than the list in `bootstrap/iam.tf`.
