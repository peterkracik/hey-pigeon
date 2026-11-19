# The token table: tokens/{sha256(email)} → [device tokens]. Native mode, in
# the functions' region. Protected from deletion — a destroy leaves it in
# place (deletion_policy ABANDON is the default); drop it by hand if wanted.
#
# If the project already has a "(default)" database, import it instead of
# creating a second one (the location is immutable):
#   terraform import google_firestore_database.default "(default)"
resource "google_firestore_database" "default" {
  name                    = "(default)"
  location_id             = var.region
  type                    = "FIRESTORE_NATIVE"
  delete_protection_state = "DELETE_PROTECTION_ENABLED"
}

# Read status: opens/{token} → { mailboxHash, createdAt, expiresAt, events }.
# Firestore deletes a document once its `expiresAt` has passed (within about
# a day), 30 days after the message was registered (relay/src/opens.js).
resource "google_firestore_field" "opens_ttl" {
  database   = google_firestore_database.default.name
  collection = "opens"
  field      = "expiresAt"

  ttl_config {}
}
