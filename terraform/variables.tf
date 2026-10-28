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
  description = "OAuth client ids whose access tokens register-token accepts: the iOS client(s) only. The desktop never registers a device."
  type        = list(string)
}

variable "apns_secret_writers" {
  description = "IAM members allowed to add versions to the apns-key secret, e.g. a Doppler sync service account: [\"serviceAccount:secret-sync@<project>.iam.gserviceaccount.com\"]. Empty = the key is uploaded by hand with gcloud."
  type        = list(string)
  default     = []
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
}
