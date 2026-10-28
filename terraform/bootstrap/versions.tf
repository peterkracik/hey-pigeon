terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }

  # First apply runs with local state (this stack creates the bucket). Then
  # move the state into it so nothing stays on a laptop — see ../README.md:
  #   terraform init -migrate-state \
  #     -backend-config="bucket=<state_bucket output>" -backend-config="prefix=bootstrap"
  # and uncomment:
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
