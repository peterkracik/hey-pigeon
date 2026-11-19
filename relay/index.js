// Cloud Run functions entry point. One zip, three functions: Terraform
// deploys `onMailChange` (Pub/Sub-triggered), `registerToken` (HTTPS) and
// `opens` (HTTPS, read status) from this file with different entry points
// (terraform/functions.tf).
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
import { createOpensHandler } from "./src/opens-handlers.js";
import { createOpenStore } from "./src/opens.js";
import { createAppleRanges } from "./src/ranges.js";

function env(name, fallback) {
  const v = process.env[name];
  if (v === undefined || v === "") {
    if (fallback !== undefined) return fallback;
    throw new Error(`missing env ${name}`);
  }
  return v;
}

const db = new Firestore();
const auth = createAuth({
  clientIds: env("GOOGLE_CLIENT_IDS", "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
  log: console,
});

const handlers = createHandlers({
  tokens: createTokenStore(db),
  // APNs is lazy: the key is read from Secret Manager on the first push, so
  // `registerToken` instances never touch it and a missing key surfaces as
  // a logged push failure rather than a crash at startup.
  apns: createApns({
    keyId: env("APNS_KEY_ID", ""),
    teamId: env("APNS_TEAM_ID", ""),
    topic: env("APNS_TOPIC", "app.heypigeon.ios"),
    loadKey: () => loadSecret(env("APNS_SECRET_NAME")),
  }),
  auth,
  topic: env("PUBSUB_TOPIC", ""),
  opensUrl: env("OPENS_URL", "").replace(/\/+$/, ""),
  log: console,
});

functions.cloudEvent("onMailChange", handlers.onMailChange);
functions.http("registerToken", handlers.registerToken);

// Read status. No APNs here: telling the phone about an open (`onOpen`) is
// not built yet, so this function has no reason to hold the key.
functions.http(
  "opens",
  createOpensHandler({
    opens: createOpenStore(db),
    auth,
    ranges: createAppleRanges({ log: console }),
    publicUrl: env("OPENS_PUBLIC_URL", "").replace(/\/+$/, ""),
    log: console,
  }),
);
