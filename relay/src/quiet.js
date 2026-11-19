// What a library prints on an `opens` instance, cut down to what cannot
// carry anything about a request.
//
// The handler logs through its own logger and says only what its privacy
// contract allows (src/opens-handlers.js). But the handler is not the only
// thing in the process that prints: Express and its body parser reject a
// request they cannot parse before the handler is ever called, and
// `console.error` the error with its stack —
//   URIError: Failed to decode param 'o/%E0%A4%A.gif'
//   SyntaxError: Expected ',' or '}' ... in JSON at position 43
//   SyntaxError: Unexpected token 'a', "aaaaaaaaaa"... is not valid JSON
// — the path of a pixel request, a fragment of a body that may hold a
// token. The functions framework prints the same way for a rejection the
// handler did not catch.
//
// So on this instance `console.error` and `console.warn` keep the class
// name of what they were given and drop the rest: enough to see that
// something is being refused, nothing of what it was. The handler's own
// logger is bound to the real methods before this is installed.

/** The line that replaces a library's error output: class names only. */
export function quietLine(args) {
  const names = args.map((a) => {
    if (a instanceof Error) return a.constructor?.name || "Error";
    if (typeof a === "string") {
      // `err.stack || String(err)`: "URIError: Failed to decode …\n    at …"
      const named = /^([A-Z][A-Za-z]*(?:Error|Warning|Exception))\b/.exec(a);
      return named ? named[1] : "message";
    }
    return typeof a;
  });
  return `opens: output withheld (${names.join(", ") || "empty"})`;
}

/**
 * Bind a logger to the console's real methods, then replace
 * `console.error` / `console.warn` with the reduced line. Returns the
 * logger for this code's own, vetted lines.
 */
export function installQuietConsole(target = console) {
  const log = {
    info: target.info.bind(target),
    warn: target.warn.bind(target),
    error: target.error.bind(target),
  };
  target.error = (...args) => log.error(quietLine(args));
  target.warn = (...args) => log.warn(quietLine(args));
  return log;
}
