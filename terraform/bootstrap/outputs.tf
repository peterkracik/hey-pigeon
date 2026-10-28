output "state_bucket" {
  description = "GCS bucket holding Terraform state. Root stack: -backend-config=\"bucket=<this>\"; GitHub variable TF_STATE_BUCKET."
  value       = google_storage_bucket.tfstate.name
}

output "workload_identity_provider" {
  description = "GitHub variable GCP_WORKLOAD_IDENTITY_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_sa_email" {
  description = "GitHub variable GCP_DEPLOYER_SA."
  value       = google_service_account.relay_deployer.email
}

output "relay_fn_sa_email" {
  value = google_service_account.relay_fn.email
}

output "relay_build_sa_email" {
  value = google_service_account.relay_build.email
}

output "project_number" {
  value = local.project_number
}
