variable "project_id" {
  description = "Same project as terraform/bootstrap."
  type        = string
}

variable "region" {
  description = "Region for the functions, the topic trigger, Firestore and the source bucket."
  type        = string
  default     = "europe-west1"
}

variable "apns_key_id" {
  description = "Key ID of the APNs auth key (Apple Developer → Keys). The .p8 itself goes into Secret Manager by hand."
  type        = string
}

variable "apns_team_id" {
  description = "Apple Developer Team ID."
  type        = string
}

variable "apns_topic" {
  description = "APNs topic = the iOS bundle id."
  type        = string
  default     = "app.heypigeon.ios"
}

variable "google_client_ids" {
  description = "OAuth client ids whose access tokens the relay accepts: the iOS client(s). The Mac's goes in google_mac_client_id."
  type        = list(string)
}

variable "google_mac_client_id" {
  description = "The Mac app's OAuth client id (GOOGLE_MAC_CLIENT_ID in its build; HEYPIGEON_MAC_OAUTH_CLIENT_ID in CI). The Mac registers no device, but it asks register-token where read status lives and will use opens; without this its tokens are refused. Empty: only the ids above are accepted (also right when the Mac is built with the iOS client)."
  type        = string
  default     = ""
}

variable "opens_domain" {
  description = "Custom domain for the read-status pixel (o.heypigeon.app). Empty: the opens function is used at its run.app URL and no mapping is created. Set it only after the deployer service account is a verified owner of the domain and the DNS record exists (README)."
  type        = string
  default     = ""
}

variable "node_runtime" {
  description = "Cloud Run functions runtime. Node 20 is end-of-life; 22 is the floor."
  type        = string
  default     = "nodejs22"
}

locals {
  # Created by terraform/bootstrap with fixed account ids.
  relay_fn_sa    = "relay-fn@${var.project_id}.iam.gserviceaccount.com"
  relay_build_sa = "relay-build@${var.project_id}.iam.gserviceaccount.com"
  relay_dir      = "${path.module}/../relay"

  # Every client the relay accepts, once each, without the empty strings an
  # unset CI value leaves behind. Known at plan time, like everything in a
  # function's environment has to be.
  google_client_ids = distinct(compact(concat(var.google_client_ids, [var.google_mac_client_id])))
}
