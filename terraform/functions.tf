# Function source: the relay folder, zipped from an explicit file list (no
# node_modules — Cloud Build runs `npm ci` from package-lock.json). The
# object name carries the zip hash, so a code change is a new object and
# therefore a new revision on the next apply; an unchanged relay is a no-op.
data "archive_file" "relay" {
  type        = "zip"
  output_path = "${path.module}/.build/relay.zip"

  source {
    content  = file("${local.relay_dir}/index.js")
    filename = "index.js"
  }
  source {
    content  = file("${local.relay_dir}/package.json")
    filename = "package.json"
  }
  source {
    content  = file("${local.relay_dir}/package-lock.json")
    filename = "package-lock.json"
  }
  dynamic "source" {
    for_each = fileset("${local.relay_dir}/src", "*.js")
    content {
      content  = file("${local.relay_dir}/src/${source.value}")
      filename = "src/${source.value}"
    }
  }
}

resource "google_storage_bucket" "relay_src" {
  name                        = "${var.project_id}-relay-src"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30
    }
  }
}

resource "google_storage_bucket_object" "relay" {
  name   = "relay-${data.archive_file.relay.output_md5}.zip"
  bucket = google_storage_bucket.relay_src.name
  source = data.archive_file.relay.output_path
}

# IAM set in this stack and in bootstrap takes a moment to propagate; on a
# first apply the function create can otherwise race it.
resource "time_sleep" "iam_propagation" {
  create_duration = "60s"
  depends_on = [
    google_secret_manager_secret_iam_member.relay_fn_reads_apns_key,
    google_pubsub_topic_iam_member.gmail_publisher,
  ]
}

locals {
  apns_env = {
    APNS_KEY_ID      = var.apns_key_id
    APNS_TEAM_ID     = var.apns_team_id
    APNS_TOPIC       = var.apns_topic
    APNS_SECRET_NAME = google_secret_manager_secret.apns_key.id # projects/<p>/secrets/apns-key
  }
}

# Pub/Sub → silent APNs push. No public URL: Eventarc delivers from inside
# the project, which ALLOW_INTERNAL_ONLY admits.
resource "google_cloudfunctions2_function" "on_mail_change" {
  name        = "on-mail-change"
  location    = var.region
  description = "Hey Pigeon relay: Gmail watch event → silent APNs push (sees email + historyId only)"

  build_config {
    runtime           = var.node_runtime
    entry_point       = "onMailChange"
    service_account   = "projects/${var.project_id}/serviceAccounts/${local.relay_build_sa}"
    docker_repository = google_artifact_registry_repository.relay.id

    source {
      storage_source {
        bucket = google_storage_bucket.relay_src.name
        object = google_storage_bucket_object.relay.name
      }
    }
  }

  service_config {
    service_account_email = local.relay_fn_sa
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    available_memory      = "256M"
    timeout_seconds       = 60
    min_instance_count    = 0
    max_instance_count    = 3
    environment_variables = local.apns_env
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.gmail_push.id
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = local.relay_fn_sa
  }

  depends_on = [time_sleep.iam_propagation]
}

# The trigger identity must be allowed to invoke the service it targets.
resource "google_cloud_run_v2_service_iam_member" "on_mail_change_invoker" {
  location = var.region
  name     = google_cloudfunctions2_function.on_mail_change.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${local.relay_fn_sa}"
}

# Device registration: public HTTPS, authenticated by the Google access token
# in the request (relay/src/auth.js), not by Cloud Run IAM.
resource "google_cloudfunctions2_function" "register_token" {
  name        = "register-token"
  location    = var.region
  description = "Hey Pigeon relay: iOS device token registration (Google access token auth)"

  build_config {
    runtime           = var.node_runtime
    entry_point       = "registerToken"
    service_account   = "projects/${var.project_id}/serviceAccounts/${local.relay_build_sa}"
    docker_repository = google_artifact_registry_repository.relay.id

    source {
      storage_source {
        bucket = google_storage_bucket.relay_src.name
        object = google_storage_bucket_object.relay.name
      }
    }
  }

  service_config {
    service_account_email = local.relay_fn_sa
    ingress_settings      = "ALLOW_ALL"
    available_memory      = "256M"
    timeout_seconds       = 30
    min_instance_count    = 0
    max_instance_count    = 3
    environment_variables = merge(local.apns_env, {
      GOOGLE_CLIENT_IDS = join(",", var.google_client_ids)
      PUBSUB_TOPIC      = google_pubsub_topic.gmail_push.id # projects/<p>/topics/gmail-push
    })
  }

  depends_on = [time_sleep.iam_propagation]
}

resource "google_cloud_run_v2_service_iam_member" "register_token_public" {
  location = var.region
  name     = google_cloudfunctions2_function.register_token.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
