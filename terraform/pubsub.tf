# Gmail publishes {emailAddress, historyId} here on every INBOX change for
# every account that called users.watch with this topic. One topic serves all
# accounts; the address in the message routes to the right device tokens.
resource "google_pubsub_topic" "gmail_push" {
  name = "gmail-push"

  # Nothing subscribes but the Eventarc trigger; undeliverable messages are
  # worthless after minutes anyway.
  message_retention_duration = "600s"
}

# This is the whole trick: Google's Gmail push account may publish, so
# users.watch works for any mailbox without the user needing a Pub/Sub scope.
resource "google_pubsub_topic_iam_member" "gmail_publisher" {
  topic  = google_pubsub_topic.gmail_push.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:gmail-api-push@system.gserviceaccount.com"
}
