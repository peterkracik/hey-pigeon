output "register_token_url" {
  description = "The relay URL the apps are built with (HEYPIGEON_RELAY_URL); it also reports the topic and the opens URL."
  value       = google_cloudfunctions2_function.register_token.service_config[0].uri
}

output "opens_url" {
  description = "Where the opens function answers: the custom domain once mapped, else its run.app URL. The app is only told about the custom domain."
  value       = local.opens_url
}

output "opens_run_url" {
  description = "The opens function's own run.app URL; works with or without the custom domain."
  value       = google_cloudfunctions2_function.opens.service_config[0].uri
}

output "opens_domain_records" {
  description = "The DNS records Google asks for once opens_domain is mapped (a CNAME to ghs.googlehosted.com for a subdomain)."
  value       = var.opens_domain != "" ? google_cloud_run_domain_mapping.opens[0].status[0].resource_records : []
}

output "pubsub_topic" {
  description = "What the app's users.watch points at (the relay reports it on registration)."
  value       = google_pubsub_topic.gmail_push.id
}

output "apns_secret" {
  description = "Upload the .p8 here: gcloud secrets versions add apns-key --data-file=AuthKey_<KEYID>.p8"
  value       = google_secret_manager_secret.apns_key.id
}
