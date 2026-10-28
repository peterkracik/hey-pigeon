# The APNs .p8. Terraform creates the container only; the key is added out of
# band so it never enters state or a plan:
#   gcloud secrets versions add apns-key --data-file=AuthKey_<KEYID>.p8
# The function reads `latest` at runtime (relay/src/secret.js) — a secret
# with no versions would make a deploy-time mount fail.
resource "google_secret_manager_secret" "apns_key" {
  secret_id = "apns-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "relay_fn_reads_apns_key" {
  secret_id = google_secret_manager_secret.apns_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.relay_fn_sa}"
}
