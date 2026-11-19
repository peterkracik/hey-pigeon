# Google Cloud for the relay — Terraform

Everything the optional relay ([../relay/README.md](../relay/README.md): iOS
push, and the `opens` function for read status) needs in Google Cloud is
created here. Nothing is clicked together in the
console except the three things Terraform has no resource for (below).

Two stacks, on purpose:

| Stack | Who applies | What it owns |
| --- | --- | --- |
| `bootstrap/` | you, from a laptop, rarely | APIs, the Terraform state bucket, the three service accounts and their **project-level** IAM (one custom role included), Workload Identity Federation for GitHub Actions |
| `.` (root) | CI on `main`, or by hand from the Actions tab (and you, the first time) | Pub/Sub topic, Firestore database and its TTL policy, the empty APNs secret, Artifact Registry repo, source bucket, the three Cloud Run functions **and their code**, the log exclusion for `opens`, the optional domain mapping, resource-level IAM |

The split keeps the CI identity unable to grant itself anything: it can
deploy functions, topics and secrets, but it has no project IAM, service
account admin or WIF rights. That is why a new right for the deployer is
always a laptop step — one `terraform apply` in `bootstrap/` — and never
something a workflow does: a workflow that could apply bootstrap would be
a CI identity that can grant itself anything.

**The one Logging right the deployer has**, and what it costs. The
`opens` function must never exist without the exclusion that keeps its
request logs (IP address, user agent, URL per pixel request) from being
stored, so the exclusion is created by the same apply as the function, and
before it. For that the deployer holds a custom role, `relayLogExclusions`
(`bootstrap/iam.tf`): create, read, change and delete project log
exclusions, nothing else. It is narrower than `roles/logging.configWriter`,
which would add sinks, log buckets, views and links. What it does let the
CI identity do, beyond this one exclusion: add or change *any* exclusion
of the project, i.e. stop other logs of the default bucket from being
stored. It cannot exclude the Admin Activity audit log (Google never
allows that) and cannot read any log.

## What gets created

- **APIs**: Pub/Sub, Cloud Run, Cloud Functions, Cloud Build, Artifact
  Registry, Eventarc, Firestore, Secret Manager, IAM, IAM Credentials, STS,
  Resource Manager, Logging.
- **Service accounts**: `relay-fn` (function runtime + Eventarc trigger
  identity: Firestore user, event receiver, reads the APNs secret),
  `relay-build` (Cloud Build), `relay-deployer` (CI).
- **Custom role** `relayLogExclusions` on `relay-deployer` (above).
- **Workload Identity Federation**: pool `github`, provider `github-oidc`
  limited to `assertion.repository == "<github_repository>"`, bound to
  `relay-deployer`.
- **Pub/Sub topic** `gmail-push`, publishable by
  `gmail-api-push@system.gserviceaccount.com`.
- **Firestore** `(default)`, Native mode, delete protection on. A TTL policy
  on `opens.expiresAt` deletes read-status documents 30 days after
  registration.
- **Log exclusion** `opens-request-logs`: the Cloud Run request log of the
  `opens` service is not stored (`logging.tf`).
- **Secret Manager** secret `apns-key` — empty; you upload the `.p8`.
- **Artifact Registry** Docker repo `relay` (keep last 5 images, delete after 30 days).
- **GCS**: `<project>-tfstate` (versioned) and `<project>-relay-src`.
- **Cloud Run functions** (2nd gen, Node 22): `on-mail-change` (Pub/Sub
  trigger, internal ingress only), `register-token` (public HTTPS,
  authenticated by the caller's Google access token) and `opens` (public
  HTTPS: the read-status pixel, open to anyone, and three routes
  authenticated like `register-token`; 512M, one CPU, 80 requests per
  instance, at most 3 instances).
- **Domain mapping** `o.heypigeon.app` → `opens`, only when `opens_domain`
  is set (below). Off by default.

Cost at personal volume: $0 — every service above has a free tier that a
few hundred pushes and pixel requests a day do not approach; a Cloud Run
domain mapping is free; there is no load balancer and no minimum instance.
The pixel is public, so its ceiling is what bounds a flood: 3 instances
of one CPU, 240 requests at once. That ceiling is not free — three CPUs
busy around the clock for a month would be on the order of a couple of
hundred dollars — so it is a bound on abuse, not a promise of $0 under
attack. A budget alert on the project is the owner's to set; Terraform
does not create one.

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

# 4. The APNs key — the only secret, and it never touches Terraform.
#    By hand, or from whatever secret manager you use, as a new version of
#    the `apns-key` secret Terraform created (raw PEM, -----BEGIN PRIVATE KEY-----).
gcloud secrets versions add apns-key --data-file=AuthKey_<KEYID>.p8 --project <PROJECT_ID>

# 5. The relay URL for the app
terraform output register_token_url
```

**Upgrading an existing deployment to the one with `opens`** — once, before
the pull request that adds it is merged:

```sh
cd terraform/bootstrap
terraform init -backend-config="bucket=<state bucket>" -backend-config="prefix=bootstrap"
terraform apply -var project_id=<PROJECT_ID>   # adds the relayLogExclusions role and its binding, nothing else
```

Everything after that is the Action's. If the merge comes first, the apply
on `main` fails at `google_logging_project_exclusion.opens_requests` with a
403; the `opens` function and its public access depend on the exclusion and
are not created, and `register-token` keeps its previous revision. Grant
the role, then Actions → deploy-relay → Run workflow → `apply`.

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

By hand: Actions → deploy-relay → Run workflow, on `main`, with `plan`
(default) or `apply`. It is the same job in the same `infra` environment,
so the environment's reviewers and branch rule apply to it as to a push.
The workflow stops a run started from another branch or tag at its first
step, but only as a guard against a slip: a dispatched run uses the
workflow file of its own ref, so a branch could remove that step. What
holds is the `infra` environment itself — **set "Deployment branches" to
`main` only** (and required reviewers, if wanted) under Settings →
Environments → infra. Without that rule, anyone who can push a branch and
run a workflow can apply from it.

The `terraform` job runs in the GitHub **environment `infra`**
(Settings → Environments → New environment). Put these on that environment —
in this repo they are synced there from Doppler; the workflow reads each as a
variable first and a secret second, so either kind works, and none of them is
sensitive. Protection rules on the environment — required reviewers,
deployment branches limited to `main` — gate every apply.

| Variable | Value |
| --- | --- |
| `GCP_PROJECT_ID` | the project id |
| `TF_STATE_BUCKET` | bootstrap output `state_bucket` |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | bootstrap output `workload_identity_provider` |
| `GCP_DEPLOYER_SA` | bootstrap output `deployer_sa_email` |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | from Apple |
| `HEYPIGEON_IOS_OAUTH_CLIENT_ID` | the iOS OAuth client id |
| `HEYPIGEON_MAC_OAUTH_CLIENT_ID` (optional) | the Mac app's OAuth client id — the value the `macos` environment already holds for `publish-macos`; a job only sees its own environment, so it has to be on `infra` too. Unset, or equal to the iOS one: nothing changes. Set: `register-token` and `opens` get a new revision that also accepts the Mac's tokens |
| `OPENS_DOMAIN` (optional) | `o.heypigeon.app`, once the two steps under "The pixel's own domain" are done; unset = the apps are told there is no read status |

## The pixel's own domain (`o.heypigeon.app`)

Without `OPENS_DOMAIN` the `opens` function is deployed and answers at its
run.app URL (`terraform output opens_run_url`), but `register-token`
reports no `opensUrl`, so no app can use it (read status is then
unavailable in the apps) and no pixel is ever sent with a run.app address. To put it on `o.heypigeon.app` — by the Action, with two things
done by hand once, in this order:

1. **Verified owner.** Google lets only a verified owner of a domain map
   it. In [Search Console](https://search.google.com/search-console), on
   the verified `heypigeon.app` domain property: Settings → Users and
   permissions → Add user → the deployer's address (bootstrap output
   `deployer_sa_email`), permission **Owner**.
2. **DNS**, wherever `heypigeon.app` is hosted: `o  CNAME  ghs.googlehosted.com.`
   (Terraform manages no DNS; `terraform output opens_domain_records`
   shows what Google asks for once the mapping exists.)

Then set `OPENS_DOMAIN=o.heypigeon.app` on the `infra` environment and run
the workflow with `apply`. Google issues the certificate after the record
resolves, usually within the hour; until then the domain does not answer
and the run.app URL still does. From that apply on, `register-token`
reports `https://o.heypigeon.app`, so read status in the apps can start
within the hour it takes the certificate; mail sent in that hour points at
a host that is not up yet. If step 1 is missing the apply fails on the mapping alone; unset the
variable to get back to a green apply.

Everything else about the deploy (region, runtime, topic name) is in the
Terraform files.

Why an environment rather than repository-level values: a job only sees an
environment's values when it names the environment, which keeps the Google
Cloud configuration scoped to this one job, and the environment is where
GitHub attaches approval rules and deployment history.

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
  `opens` is public for the same reason, and because its pixel is fetched
  by the recipients' mail clients, which have no identity at all.
- The **log exclusion is in this stack, not in bootstrap**, so that no
  ordering depends on a person: the function `depends_on` it. It drops the
  request log of `opens` only; the function's own output and the other
  functions' request logs are kept.
- **Apple's egress ranges are fetched by the function**, not shipped in the
  zip, so `opens` needs outbound internet (the default) and nothing here.
- The **Eventarc trigger** runs as `relay-fn`, which must hold
  `roles/run.invoker` on `on-mail-change` and `roles/eventarc.eventReceiver`
  — both granted here and in bootstrap. Eventarc creates the push
  subscription itself; no Terraform `google_pubsub_subscription`.
- The **build** uses its own `relay-build` account instead of the Compute
  Engine default, which newer projects may not have (or not with Editor).
- The deployer is **not** `roles/editor`: Editor cannot manage IAM anyway,
  and it is far broader than the list in `bootstrap/iam.tf`.
