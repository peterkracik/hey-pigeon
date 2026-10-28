# Every API the relay needs, enabled once here (the CI deployer only gets to
# look at them: roles/serviceusage.serviceUsageViewer).
locals {
  apis = toset([
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "eventarc.googleapis.com",
    "firestore.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "logging.googleapis.com",
  ])
}

resource "google_project_service" "api" {
  for_each = local.apis

  service            = each.value
  disable_on_destroy = false
}

data "google_project" "this" {
  depends_on = [google_project_service.api]
}

# Service agents are created lazily after an API is enabled; the first
# Eventarc trigger fails with "Permission denied while using the Eventarc
# Service Agent" if it does not exist yet. Asking for them explicitly avoids
# that race on the root stack's first apply.
resource "google_project_service_identity" "eventarc" {
  provider = google-beta

  service    = "eventarc.googleapis.com"
  depends_on = [google_project_service.api]
}

resource "google_project_service_identity" "pubsub" {
  provider = google-beta

  service    = "pubsub.googleapis.com"
  depends_on = [google_project_service.api]
}

locals {
  project_number     = data.google_project.this.number
  pubsub_agent       = "service-${local.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  functions_agent    = "service-${local.project_number}@gcf-admin-robot.iam.gserviceaccount.com"
  gmail_push_account = "gmail-api-push@system.gserviceaccount.com"
}
