// Cloud Run functions entry point. One zip, two functions: Terraform
// deploys `onMailChange` (Pub/Sub-triggered) and `registerToken` (HTTPS)
// from this file with different entry points (terraform/functions.tf).
//
// Everything with a network side is injected into src/handlers.js so the
// handlers are unit-testable; this file is the only place that knows about
// Firestore, Secret Manager, APNs and the environment.

import functions from "@google-cloud/functions-framework";
import { Firestore } from "@google-cloud/firestore";

import { createHandlers } from "./src/handlers.js";
import { createTokenStore } from "./src/tokens.js";
import { createApns } from "./src/apns.js";
import { createAuth } from "./src/auth.js";
import { loadSecret } from "./src/secret.js";

function env(name, fallback) {
  const v = process.env[name];
  if (v === undefined || v === "") {
    if (fallback !== undefined) return fallback;
    throw new Error(`missing env ${name}`);
  }
  return v;
}

const handlers = createHandlers({
  tokens: createTokenStore(new Firestore()),
  // APNs is lazy: the key is read from Secret Manager on the first push, so
  // `registerToken` instances never touch it and a missing key surfaces as
  // a logged push failure rather than a crash at startup.
  apns: createApns({
    keyId: env("APNS_KEY_ID", ""),
    teamId: env("APNS_TEAM_ID", ""),
    topic: env("APNS_TOPIC", "app.heypigeon.ios"),
    loadKey: () => loadSecret(env("APNS_SECRET_NAME")),
  }),
  auth: createAuth({
    clientIds: env("GOOGLE_CLIENT_IDS", "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
    log: console,
  }),
  topic: env("PUBSUB_TOPIC", ""),
  log: console,
});

functions.cloudEvent("onMailChange", handlers.onMailChange);
functions.http("registerToken", handlers.registerToken);
