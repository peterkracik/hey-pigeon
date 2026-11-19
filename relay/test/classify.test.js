import { test } from "node:test";
import assert from "node:assert/strict";

import { classify, GRACE_MS } from "../src/classify.js";

const LATER = GRACE_MS + 1;
const APPLE_MAIL = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)";
const GMAIL = "Mozilla/5.0 (Windows NT 5.1; rv:11.0) Gecko Firefox/11.0 (via ggpht.com GoogleImageProxy)";
const fetch = (over = {}) => ({ method: "GET", userAgent: APPLE_MAIL, fromApple: false, ageMs: LATER, ...over });

test("Gmail's image proxy is an open", () => {
  assert.equal(classify(fetch({ userAgent: GMAIL })), "opened");
  // Whatever the address list says or does not say.
  assert.equal(classify(fetch({ userAgent: GMAIL, fromApple: null })), "opened");
});

test("a mail client or browser asking directly is an open", () => {
  assert.equal(classify(fetch()), "opened");
  assert.equal(classify(fetch({ userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Microsoft Outlook 16.0" })), "opened");
  assert.equal(classify(fetch({ userAgent: "YahooMailProxy; https://help.yahoo.com/kb/yahoo-mail-proxy-SLN28749.html" })), "opened");
});

test("Apple's privacy proxy is hidden, never opened", () => {
  // By its address, whatever it calls itself.
  assert.equal(classify(fetch({ fromApple: true, userAgent: "Mozilla/5.0" })), "hidden");
  assert.equal(classify(fetch({ fromApple: true })), "hidden");
  // By what it calls itself, when the address is not on the list.
  assert.equal(classify(fetch({ fromApple: false, userAgent: "Mozilla/5.0" })), "hidden");
});

test("without Apple's list the proxy is still hidden, and only what can be told from it is opened", () => {
  assert.equal(classify(fetch({ fromApple: null, userAgent: "Mozilla/5.0" })), "hidden");
  assert.equal(classify(fetch({ fromApple: null, userAgent: " Mozilla/5.0 " })), "hidden");
  assert.equal(classify(fetch({ fromApple: null })), "opened");
  assert.equal(classify(fetch({ fromApple: null, userAgent: "" })), null);
});

test("anything inside the grace window is ignored", () => {
  for (const userAgent of [GMAIL, APPLE_MAIL, "Mozilla/5.0"]) {
    assert.equal(classify(fetch({ userAgent, ageMs: 0 })), null);
    assert.equal(classify(fetch({ userAgent, ageMs: GRACE_MS - 1, fromApple: true })), null);
  }
  assert.equal(classify(fetch({ ageMs: GRACE_MS })), "opened");
  // A clock that ran backwards, or no age at all, is not past the window.
  assert.equal(classify(fetch({ ageMs: -5 })), null);
  assert.equal(classify(fetch({ ageMs: NaN })), null);
  assert.equal(classify(fetch({ ageMs: undefined })), null);
});

test("scanners, scripts and a missing user agent are ignored", () => {
  for (const userAgent of [
    "",
    "curl/8.5.0",
    "python-requests/2.32",
    "Wget/1.21",
    "Go-http-client/2.0",
    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    "Barracuda Sentinel (EE)",
    "Mimecast-URL-Scanner",
    "Proofpoint URL Defense",
    "Java/17.0.2",
  ]) {
    assert.equal(classify(fetch({ userAgent })), null, userAgent);
  }
  assert.equal(classify(fetch({ userAgent: undefined })), null);
});

test("only a GET counts", () => {
  for (const method of ["HEAD", "POST", "OPTIONS", "get"]) {
    assert.equal(classify(fetch({ method })), null, method);
  }
});
