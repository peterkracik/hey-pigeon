output "register_token_url" {
  description = "Paste this into the iOS app: Settings → Notifications → Relay URL."
  value       = google_cloudfunctions2_function.register_token.service_config[0].uri
}

output "pubsub_topic" {
  description = "What the app's users.watch points at (the relay reports it on registration)."
  value       = google_pubsub_topic.gmail_push.id
}

output "apns_secret" {
  description = "Upload the .p8 here: gcloud secrets versions add apns-key --data-file=AuthKey_<KEYID>.p8"
  value       = google_secret_manager_secret.apns_key.id
}
