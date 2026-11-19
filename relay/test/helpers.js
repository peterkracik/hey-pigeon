export function fakeTokens(initial = {}) {
  const docs = new Map(Object.entries(initial));
  return {
    docs,
    async get(hash) {
      return docs.get(hash) ?? [];
    },
    async upsert(hash, entry) {
      const rest = (docs.get(hash) ?? []).filter((t) => t.token !== entry.token);
      rest.push({ ...entry, updatedAt: 1 });
      docs.set(hash, rest);
    },
    async remove(hash, token) {
      const rest = (docs.get(hash) ?? []).filter((t) => t.token !== token);
      if (rest.length) docs.set(hash, rest);
      else docs.delete(hash);
    },
  };
}

export function fakeApns(script = () => ({ status: 200 })) {
  const sent = [];
  return {
    sent,
    async send(msg) {
      sent.push(msg);
      const r = script(msg);
      if (r instanceof Error) throw r;
      return r;
    },
  };
}

export function fakeAuth(map) {
  return {
    async verify(bearer) {
      return map[bearer] ?? null;
    },
  };
}

export function silentLog() {
  const lines = [];
  const push = (level) => (...args) => lines.push(`${level} ${args.join(" ")}`);
  return { lines, info: push("info"), warn: push("warn"), error: push("error") };
}

export function pubsubEvent(obj) {
  return { data: { message: { data: Buffer.from(JSON.stringify(obj)).toString("base64") } } };
}

export function fakeRes() {
  const res = {
    statusCode: 200,
    headers: {},
    body: undefined,
    ended: false,
    set(k, v) {
      this.headers[k] = v;
      return this;
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(obj) {
      this.body = obj;
      this.ended = true;
      return this;
    },
    end(body) {
      if (body !== undefined) this.body = body;
      this.ended = true;
      return this;
    },
  };
  return res;
}

export function fakeReq({ method = "POST", headers = {}, body, path = "/" } = {}) {
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return { method, body, path, get: (k) => lower[k.toLowerCase()] };
}

/**
 * The `opens` table in memory, with the shape of src/opens.js. `calls`
 * lists every method the handler reached for, arguments included — what
 * the tests search to show that an address or a user agent never got as
 * far as the store.
 */
export function fakeOpens(initial = {}) {
  const docs = new Map(Object.entries(initial).map(([k, v]) => [k, { events: [], ...v }]));
  const calls = [];
  const live = (token, nowMs) => {
    const d = docs.get(token);
    return d && d.expiresAt > nowMs ? d : null;
  };
  return {
    docs,
    calls,
    writes: () => calls.filter((c) => c[0] !== "get" && c[0] !== "getMany"),
    async get(token, nowMs) {
      calls.push(["get", token, nowMs]);
      return live(token, nowMs);
    },
    async register(token, mailboxHash, nowMs, ttlMs) {
      calls.push(["register", token, mailboxHash, nowMs, ttlMs]);
      const current = live(token, nowMs);
      if (current) return current.mailboxHash === mailboxHash ? "exists" : "taken";
      docs.set(token, { mailboxHash, createdAt: nowMs, expiresAt: nowMs + ttlMs, events: [] });
      return "created";
    },
    async append(token, event, cap, nowMs) {
      calls.push(["append", token, event, cap, nowMs]);
      const current = live(token, nowMs);
      if (!current || current.events.length >= cap) return false;
      current.events.push(event);
      return true;
    },
    async getMany(tokens, nowMs) {
      calls.push(["getMany", tokens, nowMs]);
      return new Map(tokens.map((t) => [t, live(t, nowMs)]).filter(([, d]) => d));
    },
    async removeMailbox(mailboxHash) {
      calls.push(["removeMailbox", mailboxHash]);
      let removed = 0;
      for (const [token, d] of docs) {
        if (d.mailboxHash === mailboxHash) {
          docs.delete(token);
          removed += 1;
        }
      }
      return removed;
    },
  };
}

/** Apple's ranges as a fixed answer: true / false, or null for "not loaded". */
export function fakeRanges(answer = false) {
  const asked = [];
  return {
    asked,
    async contains(ip) {
      asked.push(ip);
      return typeof answer === "function" ? answer(ip) : answer;
    },
  };
}

export const DEVICE = "a".repeat(64);
export const DEVICE2 = "b".repeat(64);
