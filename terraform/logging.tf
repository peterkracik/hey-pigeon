# The request logs of the `opens` service are not kept.
#
# Cloud Run logs every request by default: the caller's IP address, the
# user agent and the URL. For the pixel that line would be a record of who
# opened which message, from where, on what — exactly what the relay
# promises not to keep (relay/README.md). This exclusion drops those lines
# before they are stored. It is narrow on purpose: only the request log of
# this one service. The function's own output (stdout / stderr) is still
# kept: its own lines (a hash prefix, a status, an error code), and for
# anything a library prints on that instance — the framework rejecting a
# request it cannot parse — the error's class name alone
# (relay/src/quiet.js). The request logs of the other two functions, which
# only the app calls, are kept as they are. Not covered by this exclusion:
# Cloud Trace, log-based metrics and any sink added to the project by hand.
#
# It lives here, not in bootstrap, so it is applied by the same
# `terraform apply` as the function, and before it: the function and its
# public invoker both depend on it (functions.tf). The deployer may manage
# log exclusions through a custom role granted in bootstrap; without that
# grant this resource fails with a 403 and nothing public is created.
resource "google_logging_project_exclusion" "opens_requests" {
  name        = "opens-request-logs"
  description = "Hey Pigeon read status: do not store request logs (IP, user agent, URL) of the opens service"

  filter = join(" AND ", [
    "resource.type=\"cloud_run_revision\"",
    "resource.labels.service_name=\"opens\"",
    "log_id(\"run.googleapis.com/requests\")",
  ])
}
