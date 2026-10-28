# Terraform state for both stacks. Versioned so a bad apply can be undone,
# never public, never force-destroyed.
resource "google_storage_bucket" "tfstate" {
  name                        = local.state_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
  }

  depends_on = [google_project_service.api]
}
