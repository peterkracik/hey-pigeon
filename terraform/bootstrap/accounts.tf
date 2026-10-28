# Three identities, three jobs. Nothing in the root stack creates or binds
# project-level IAM; it only attaches these to resources it owns.

# Runs both functions and is the Eventarc trigger's identity.
resource "google_service_account" "relay_fn" {
  account_id   = "relay-fn"
  display_name = "Hey Pigeon relay — function runtime"
  depends_on   = [google_project_service.api]
}

# Builds the function containers (Cloud Build). The Compute Engine default
# account is not relied on: it may not exist and may not carry Editor.
resource "google_service_account" "relay_build" {
  account_id   = "relay-build"
  display_name = "Hey Pigeon relay — Cloud Build"
  depends_on   = [google_project_service.api]
}

# What GitHub Actions becomes through Workload Identity Federation.
resource "google_service_account" "relay_deployer" {
  account_id   = "relay-deployer"
  display_name = "Hey Pigeon relay — Terraform deployer (CI)"
  depends_on   = [google_project_service.api]
}

# Optional: the identity Doppler (or another secret manager) uses to write
# the APNs key. Gets rights on that one secret in the root stack
# (`apns_secret_writers`), nothing else.
resource "google_service_account" "secret_sync" {
  count = var.create_secret_sync_account ? 1 : 0

  account_id   = "secret-sync"
  display_name = "Hey Pigeon — external secret sync (Doppler)"
  depends_on   = [google_project_service.api]
}
