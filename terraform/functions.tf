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

  # After register-token, not alongside it: gen2 functions stage their source
  # in a Google-managed bucket (gcf-v2-sources-<project number>-<region>)
  # created on first use, and two functions racing to create it on a fresh
  # project end with a 409 for one of them. Sequential = one creates, the
  # other reuses.
  depends_on = [time_sleep.iam_propagation, google_cloudfunctions2_function.register_token]
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
      GOOGLE_CLIENT_IDS = join(",", local.google_client_ids)
      PUBSUB_TOPIC      = google_pubsub_topic.gmail_push.id # projects/<p>/topics/gmail-push
      # Where read status lives, reported to the app beside the topic so it
      # still needs one setting: the pixel's own domain once it is mapped,
      # empty (the app is told there is none) until then. Deliberately not
      # the opens function's run.app URL: that is unknown until the function
      # exists, and one unknown value makes the provider plan this whole map
      # away (the postcondition below is what caught it).
      OPENS_URL = var.opens_domain != "" ? "https://${var.opens_domain}" : ""
    })
  }

  # opens first, then this one, then on-mail-change: see on-mail-change for
  # why the functions are created one after the other.
  depends_on = [time_sleep.iam_propagation, google_cloudfunctions2_function.opens]

  # A value in the map above that is unknown at plan time makes the provider
  # plan every other variable away. Fail the plan or the apply here rather
  # than leave registration quietly broken.
  lifecycle {
    postcondition {
      condition = alltrue([
        for name in ["GOOGLE_CLIENT_IDS", "PUBSUB_TOPIC", "APNS_SECRET_NAME"] :
        try(self.service_config[0].environment_variables[name], "") != ""
      ])
      error_message = "register-token would lose its environment variables: a value in the map is unknown at plan time."
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "register_token_public" {
  location = var.region
  name     = google_cloudfunctions2_function.register_token.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ---------------------------------------------------------------------------
# Read status (docs/specs/read-status.md): the `opens` function. Public
# HTTPS like register-token; its four routes do their own checking
# (relay/src/opens-handlers.js). The pixel route is the one endpoint of the
# relay that strangers' mail clients call.

locals {
  # Where the opens function answers: the custom domain once it is mapped
  # (var.opens_domain), its own run.app URL until then. An output only —
  # the app is told about the custom domain alone (OPENS_URL above).
  opens_url = var.opens_domain != "" ? "https://${var.opens_domain}" : google_cloudfunctions2_function.opens.service_config[0].uri
}

resource "google_cloudfunctions2_function" "opens" {
  name        = "opens"
  location    = var.region
  description = "Hey Pigeon relay: read status for sent mail (token, mailbox hash, open times; never mail, never addresses)"

  build_config {
    runtime           = var.node_runtime
    entry_point       = "opens"
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
    # Twice the other two: an instance holds Apple's egress ranges in memory
    # (relay/src/ranges.js), some hundreds of thousands of them. A synthetic
    # 300,000-line list parsed at about 237 MB of resident memory locally,
    # so 256M is not enough; the real number is still to be read off the
    # deployed function.
    available_memory = "512M"
    # A whole CPU and many requests per instance. Left unset, a function
    # of this size gets a fraction of a CPU and takes one request at a
    # time: five instances were five requests, and five slow ones from a
    # stranger would have held up every real open and the app's own
    # routes. Every route here waits on I/O (a Firestore read, Google's
    # tokeninfo), which one Node process does eighty of at once without
    # effort; more than one request per instance needs a full CPU.
    available_cpu                    = "1"
    max_instance_request_concurrency = 80
    # Nothing here takes seconds; a request that does is cut off.
    timeout_seconds    = 15
    min_instance_count = 0
    # 3 × 80 = 240 requests at once, and the ceiling on what a flood can
    # cost: three CPUs busy, never more. At personal volume the function
    # runs for seconds a day, far inside the free tier.
    max_instance_count = 3
    environment_variables = {
      GOOGLE_CLIENT_IDS = join(",", local.google_client_ids)
      # The pixel's address, and the only one registration ever hands out.
      # Empty until the domain is mapped: registration is then refused
      # (503), so no message is sent pointing at a run.app address.
      OPENS_PUBLIC_URL = var.opens_domain != "" ? "https://${var.opens_domain}" : ""
    }
  }

  # The request-log exclusion first (logging.tf): Cloud Run writes one log
  # line per request, with the caller's IP address, user agent and the full
  # URL — for the pixel, who opened which message from where. This function
  # must never exist without the exclusion. If the exclusion cannot be
  # created (the deployer lacks the role from terraform/bootstrap), the
  # apply fails there and this function is not created at all.
  depends_on = [
    time_sleep.iam_propagation,
    google_logging_project_exclusion.opens_requests,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "opens_public" {
  location = var.region
  name     = google_cloudfunctions2_function.opens.name
  role     = "roles/run.invoker"
  member   = "allUsers"

  depends_on = [google_logging_project_exclusion.opens_requests]
}

# o.heypigeon.app → the opens service. Off until var.opens_domain is set:
# Google only lets a verified owner of the domain map it, so the deployer
# service account has to be added as an owner in Search Console first, and
# the DNS record is the domain owner's to add (terraform/README.md). Cloud
# Run domain mappings are free and "preview" at Google.
resource "google_cloud_run_domain_mapping" "opens" {
  count = var.opens_domain != "" ? 1 : 0

  location = var.region
  name     = var.opens_domain

  metadata {
    namespace = var.project_id
  }

  spec {
    route_name = google_cloudfunctions2_function.opens.name
  }
}
