# Container images the function builds produce. Managed here (rather than the
# auto-created gcf-artifacts repo) so old images are cleaned up.
resource "google_artifact_registry_repository" "relay" {
  location      = var.region
  repository_id = "relay"
  description   = "Hey Pigeon relay function images"
  format        = "DOCKER"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-last-5"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days
    }
  }
}
