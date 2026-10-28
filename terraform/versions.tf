terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Bucket and prefix come from backend.hcl (copy backend.hcl.example) or
  # -backend-config flags; a backend block cannot read variables.
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
