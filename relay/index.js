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
import { installQuietConsole } from "./src/quiet.js";
import { createOpenPush } from "./src/open-push.js";

function env(name, fallback) {
  const v = process.env[name];
  if (v === undefined || v === "") {
    if (fallback !== undefined) return fallback;
    throw new Error(`missing env ${name}`);
  }
  return v;
}

// One instance serves one function. On the one that serves `opens`,
// nothing but this code's own lines may reach the log — the framework
// would otherwise print the path or body of a request it rejects before
// the handler runs (src/quiet.js). The other two functions keep their
// ordinary error output: only the app calls them.
const servesOpens =
  process.env.FUNCTION_TARGET === "opens" || process.env.K_SERVICE === "opens" || process.argv.includes("--target=opens");
const log = servesOpens ? installQuietConsole(console) : console;

const db = new Firestore();
const auth = createAuth({
  clientIds: env("GOOGLE_CLIENT_IDS", "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
  log,
});

const tokens = createTokenStore(db);
// APNs is lazy: the key is read from Secret Manager on the first push, so
// `registerToken` instances never touch it and a missing key surfaces as
// a logged push failure rather than a crash at startup.
const apns = createApns({
  keyId: env("APNS_KEY_ID", ""),
  teamId: env("APNS_TEAM_ID", ""),
  topic: env("APNS_TOPIC", "app.heypigeon.ios"),
  loadKey: () => loadSecret(env("APNS_SECRET_NAME")),
});

const handlers = createHandlers({
  tokens,
  apns,
  auth,
  topic: env("PUBSUB_TOPIC", ""),
  opensUrl: env("OPENS_URL", "").replace(/\/+$/, ""),
  log,
});

functions.cloudEvent("onMailChange", handlers.onMailChange);
functions.http("registerToken", handlers.registerToken);

// Read status. A stored open wakes the mailbox's registered phones with a
// silent push that says only "ask" (src/open-push.js); without APNs
// settings on this function nothing is wired and the phones learn of an
// open at their next sync, as the Mac always does.
functions.http(
  "opens",
  createOpensHandler({
    opens: createOpenStore(db),
    auth,
    ranges: createAppleRanges({ log }),
    publicUrl: env("OPENS_PUBLIC_URL", "").replace(/\/+$/, ""),
    onOpen: env("APNS_KEY_ID", "") && env("APNS_SECRET_NAME", "") ? createOpenPush({ tokens, apns, log }) : undefined,
    log,
  }),
);
