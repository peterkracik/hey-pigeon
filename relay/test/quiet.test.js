import { test } from "node:test";
import assert from "node:assert/strict";

import { installQuietConsole, quietLine } from "../src/quiet.js";

const TOKEN = "0123456789abcdef0123456789abcdef";

// What Express, its body parser and the functions framework really print
// for a request they reject before the handler runs (reproduced with
// `functions-framework --target=opens`; relay/README.md has the commands).
const uri = new URIError(`Failed to decode param 'o/%E0%A4%A.gif'`);
const json = new SyntaxError(`Unexpected token 'a', "{\\"token\\":\\"${TOKEN}" is not valid JSON`);
const leaks = ["%E0", ".gif", "o/", TOKEN, "token", "decode", "Unexpected", " at "];

test("an error is reduced to its class name", () => {
  for (const args of [[uri], [uri.stack], [json], [json.stack], ["Unhandled rejection"], [json.stack, uri], [{ url: `/o/${TOKEN}.gif` }], []]) {
    const line = quietLine(args);
    assert.match(line, /^opens: output withheld \(/);
    for (const leak of leaks) assert.ok(!line.includes(leak), `${leak} in ${line}`);
  }
  assert.equal(quietLine([uri]), "opens: output withheld (URIError)");
  assert.equal(quietLine([json.stack]), "opens: output withheld (SyntaxError)");
  assert.equal(quietLine(["Unhandled rejection", json]), "opens: output withheld (message, SyntaxError)");
});

test("installed, a library's console.error and console.warn say nothing of the request; the returned logger is untouched", () => {
  const lines = [];
  const fake = {
    info: (...a) => lines.push(`info ${a.join(" ")}`),
    warn: (...a) => lines.push(`warn ${a.join(" ")}`),
    error: (...a) => lines.push(`error ${a.join(" ")}`),
  };
  const log = installQuietConsole(fake);
  // What Express does: console.error(err.stack || err.toString()).
  fake.error(uri.stack);
  fake.error(json.stack || json.toString());
  fake.warn(`something about /o/${TOKEN}.gif`);
  assert.deepEqual(lines, [
    "error opens: output withheld (URIError)",
    "error opens: output withheld (SyntaxError)",
    "warn opens: output withheld (message)",
  ]);
  // The handler's own lines pass as written.
  log.warn("opens: pixel not recorded (14)");
  log.info("opens 1a2b3c4d registered");
  assert.deepEqual(lines.slice(3), ["warn opens: pixel not recorded (14)", "info opens 1a2b3c4d registered"]);
});
