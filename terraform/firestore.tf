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
