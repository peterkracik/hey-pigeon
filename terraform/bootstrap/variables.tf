variable "project_id" {
  description = "The Google Cloud project that holds the OAuth clients. The relay lives in the same project."
  type        = string
}

variable "region" {
  description = "Region for the state bucket; the root stack uses the same for everything else."
  type        = string
  default     = "europe-west1"
}

variable "github_repository" {
  description = "owner/name of the GitHub repository allowed to deploy through Workload Identity Federation."
  type        = string
  default     = "peterkracik/hey-pigeon"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket. Defaults to <project_id>-tfstate."
  type        = string
  default     = ""
}

locals {
  state_bucket = var.state_bucket_name != "" ? var.state_bucket_name : "${var.project_id}-tfstate"
}
