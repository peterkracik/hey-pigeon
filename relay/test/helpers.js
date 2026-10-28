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
    end() {
      this.ended = true;
      return this;
    },
  };
  return res;
}

export function fakeReq({ method = "POST", headers = {}, body } = {}) {
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return { method, body, get: (k) => lower[k.toLowerCase()] };
}

export const DEVICE = "a".repeat(64);
export const DEVICE2 = "b".repeat(64);
