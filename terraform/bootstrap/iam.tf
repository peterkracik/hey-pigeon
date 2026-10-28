locals {
  relay_fn_roles = toset([
    "roles/datastore.user",         # read/write the token table
    "roles/eventarc.eventReceiver", # receive Pub/Sub events as the trigger identity
  ])

  relay_build_roles = toset([
    "roles/cloudbuild.builds.builder", # logs, source read, image push
    "roles/artifactregistry.writer",
  ])

  # Everything the root stack creates — and nothing that could widen its own
  # access (no project IAM, no service-account admin, no WIF).
  deployer_roles = toset([
    "roles/cloudfunctions.admin",
    "roles/run.admin",
    "roles/eventarc.admin",
    "roles/pubsub.admin",
    "roles/secretmanager.admin",
    "roles/datastore.owner", # create/update the Firestore database
    "roles/storage.admin",   # state bucket objects + the source bucket
    "roles/artifactregistry.admin",
    "roles/serviceusage.serviceUsageViewer",
  ])
}

resource "google_project_iam_member" "relay_fn" {
  for_each = local.relay_fn_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.relay_fn.email}"
}

resource "google_project_iam_member" "relay_build" {
  for_each = local.relay_build_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.relay_build.email}"
}

resource "google_project_iam_member" "relay_deployer" {
  for_each = local.deployer_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.relay_deployer.email}"
}

# The deployer deploys functions that run as relay-fn and build as
# relay-build: actAs on exactly those two, not project-wide.
resource "google_service_account_iam_member" "deployer_uses_relay_fn" {
  service_account_id = google_service_account.relay_fn.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.relay_deployer.email}"
}

resource "google_service_account_iam_member" "deployer_uses_relay_build" {
  service_account_id = google_service_account.relay_build.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.relay_deployer.email}"
}

# Cloud Functions' own service agent drives the build with the custom build
# account, so it needs to act as it too.
resource "google_service_account_iam_member" "functions_agent_uses_relay_build" {
  service_account_id = google_service_account.relay_build.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.functions_agent}"
  depends_on         = [google_project_service.api]
}

# Pub/Sub push to an authenticated Cloud Run endpoint mints an OIDC token as
# the trigger identity; projects whose Pub/Sub agent predates 2021-04 need
# this explicitly, newer ones get it implicitly. Harmless either way.
resource "google_project_iam_member" "pubsub_agent_token_creator" {
  project    = var.project_id
  role       = "roles/iam.serviceAccountTokenCreator"
  member     = "serviceAccount:${local.pubsub_agent}"
  depends_on = [google_project_service_identity.pubsub]
}
