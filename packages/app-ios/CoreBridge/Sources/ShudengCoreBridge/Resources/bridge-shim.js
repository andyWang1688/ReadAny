// SPDX-License-Identifier: GPL-3.0-or-later
// JavaScriptCore 缺失的宿主 API 垫片（原型：真实 App 里由 Swift 提供网络/DB/加密）
const g = globalThis;

if (typeof g.console === "undefined") {
  g.console = {
    log: (...a) => print(a.map(String).join(" ")),
    info: (...a) => print(a.map(String).join(" ")),
    warn: (...a) => print("[warn] " + a.map(String).join(" ")),
    error: (...a) => print("[error] " + a.map(String).join(" ")),
    debug: (...a) => print(a.map(String).join(" ")),
  };
}

if (typeof g.queueMicrotask === "undefined") {
  g.queueMicrotask = (fn) => Promise.resolve().then(fn);
}
if (typeof g.setInterval === "undefined") {
  const timers = new Map();
  // id 必须单调递增：用 timers.size 的话，清掉一个 interval 后新建的会拿到
  // 同一个 id，把还在跑的那个顶掉（原 interval 既停不掉也清理不干净）。
  let nextIntervalId = 1;
  g.setInterval = (fn, ms = 0) => {
    const id = nextIntervalId++;
    const tick = () => {
      if (!timers.has(id)) return;
      fn();
      timers.set(id, setTimeout(tick, ms));
    };
    timers.set(id, setTimeout(tick, ms));
    return id;
  };
  g.clearInterval = (id) => {
    const t = timers.get(id);
    if (t) clearTimeout(t);
    timers.delete(id);
  };
}

if (typeof g.process === "undefined") {
  g.process = {
    env: {},
    version: "",
    platform: "darwin",
    versions: {},
    cwd: () => "/",
    on: () => {},
  };
}

class TextEncoderPolyfill {
  get encoding() {
    return "utf-8";
  }
  encode(input = "") {
    const str = String(input);
    const bytes = [];
    for (let i = 0; i < str.length; i++) {
      let code = str.codePointAt(i);
      if (code > 0xffff) i++;
      if (code < 0x80) bytes.push(code);
      else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63));
      else if (code < 0x10000)
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      else
        bytes.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 63),
          0x80 | ((code >> 6) & 63),
          0x80 | (code & 63),
        );
    }
    return new Uint8Array(bytes);
  }
}
class TextDecoderPolyfill {
  constructor(label = "utf-8") {
    this.encoding = label;
  }
  decode(buf = new Uint8Array()) {
    const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
    let out = "";
    for (let i = 0; i < bytes.length; ) {
      const b = bytes[i];
      if (b < 0x80) {
        out += String.fromCharCode(b);
        i++;
      } else if (b < 0xe0) {
        out += String.fromCharCode(((b & 31) << 6) | (bytes[i + 1] & 63));
        i += 2;
      } else if (b < 0xf0) {
        out += String.fromCharCode(
          ((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63),
        );
        i += 3;
      } else {
        const cp =
          ((b & 7) << 18) |
          ((bytes[i + 1] & 63) << 12) |
          ((bytes[i + 2] & 63) << 6) |
          (bytes[i + 3] & 63);
        out += String.fromCodePoint(cp);
        i += 4;
      }
    }
    return out;
  }
}
if (typeof g.TextEncoder === "undefined") g.TextEncoder = TextEncoderPolyfill;
if (typeof g.TextDecoder === "undefined") g.TextDecoder = TextDecoderPolyfill;

if (typeof g.URLSearchParams === "undefined") {
  g.URLSearchParams = class URLSearchParams {
    constructor(init = "") {
      this._m = new Map();
      if (typeof init === "string" && init) {
        for (const pair of init.replace(/^\?/, "").split("&")) {
          if (!pair) continue;
          const [k, v = ""] = pair.split("=");
          this._m.set(decodeURIComponent(k), decodeURIComponent(v));
        }
      } else if (init && typeof init === "object") {
        for (const k of Object.keys(init)) this._m.set(k, String(init[k]));
      }
    }
    get(k) {
      return this._m.has(k) ? this._m.get(k) : null;
    }
    set(k, v) {
      this._m.set(k, String(v));
    }
    has(k) {
      return this._m.has(k);
    }
    append(k, v) {
      this._m.set(k, String(v));
    }
    delete(k) {
      this._m.delete(k);
    }
    forEach(fn) {
      this._m.forEach((v, k) => fn(v, k, this));
    }
    toString() {
      return [...this._m]
        .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
        .join("&");
    }
  };
}
if (typeof g.URL === "undefined") {
  g.URL = class URL {
    constructor(input, base) {
      const raw = String(
        base ? new globalThis.URL(base).href.replace(/\/$/, "") + "/" + input : input,
      );
      const m = raw.match(/^([a-zA-Z][\w+.-]*:)\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/);
      if (!m) throw new Error("Invalid URL: " + raw);
      this.protocol = m[1];
      this.host = m[2];
      this.pathname = m[3] || "/";
      this.search = m[4] || "";
      this.hash = m[5] || "";
      this.searchParams = new g.URLSearchParams(this.search);
      this.origin = this.protocol + "//" + this.host;
      const p = this.pathname.split("/");
      this.pathname = p
        .slice(0, -1)
        .concat(p[p.length - 1])
        .join("/");
    }
    get href() {
      const q = this.searchParams.toString();
      return this.protocol + "//" + this.host + this.pathname + (q ? "?" + q : "");
    }
    toString() {
      return this.href;
    }
    get hostname() {
      return this.host.split(":")[0];
    }
  };
}

// crypto 只在下面「宿主 glue」里定义一次：随机数走 Swift(Security) 的
// __nativeRandomBytes，用 Math.random 会退化成可预测的 id。
if (typeof g.EventTarget === "undefined") {
  g.Event = class Event {
    constructor(type, init = {}) {
      this.type = type;
      Object.assign(this, init);
    }
  };
  g.CustomEvent = class CustomEvent extends g.Event {
    constructor(type, init = {}) {
      super(type, init);
      this.detail = init.detail;
    }
  };
  g.EventTarget = class EventTarget {
    constructor() {
      this._l = new Map();
    }
    addEventListener(t, fn) {
      if (!fn) return;
      if (!this._l.has(t)) this._l.set(t, new Set());
      this._l.get(t).add(fn);
    }
    removeEventListener(t, fn) {
      this._l.get(t)?.delete(fn);
    }
    dispatchEvent(e) {
      this._l.get(e.type)?.forEach((fn) => fn.call(this, e));
      return true;
    }
  };
}
if (typeof g.DOMException === "undefined") {
  g.DOMException = class DOMException extends Error {
    constructor(msg, name) {
      super(msg);
      this.name = name || "Error";
    }
  };
}

if (typeof g.AbortSignal === "undefined") {
  g.AbortSignal = class AbortSignal extends g.EventTarget {
    constructor() {
      super();
      this.aborted = false;
      this.reason = undefined;
    }
    throwIfAborted() {
      if (this.aborted) throw this.reason || new Error("aborted");
    }
    static abort(reason) {
      const s = new g.AbortSignal();
      s.aborted = true;
      s.reason = reason;
      return s;
    }
    static timeout(ms) {
      const s = new g.AbortSignal();
      setTimeout(() => {
        s.aborted = true;
        s.reason = new Error("timeout");
        s.dispatchEvent(new g.Event("abort"));
      }, ms);
      return s;
    }
  };
  g.AbortController = class AbortController {
    constructor() {
      this.signal = new g.AbortSignal();
    }
    abort(reason) {
      this.signal.aborted = true;
      this.signal.reason = reason || new g.DOMException("Aborted", "AbortError");
      this.signal.dispatchEvent(new g.Event("abort"));
    }
  };
}

if (typeof g.Headers === "undefined") {
  g.Headers = class Headers {
    constructor(init = {}) {
      this._m = new Map();
      if (init instanceof g.Headers) init.forEach((v, k) => this.set(k, v));
      else Object.entries(init).forEach(([k, v]) => this.set(k, v));
    }
    set(k, v) {
      this._m.set(String(k).toLowerCase(), String(v));
    }
    get(k) {
      return this._m.get(String(k).toLowerCase()) ?? null;
    }
    has(k) {
      return this._m.has(String(k).toLowerCase());
    }
    delete(k) {
      this._m.delete(String(k).toLowerCase());
    }
    append(k, v) {
      const key = String(k).toLowerCase();
      const old = this._m.get(key);
      this._m.set(key, old ? old + ", " + v : String(v));
    }
    keys() {
      return this._m.keys();
    }
    values() {
      return this._m.values();
    }
    forEach(fn) {
      this._m.forEach((v, k) => fn(v, k, this));
    }
    entries() {
      return this._m.entries();
    }
    [Symbol.iterator]() {
      return this._m.entries();
    }
  };
}
if (typeof g.ReadableStream === "undefined") {
  class ReadableStreamPolyfill {
    constructor(source = {}) {
      this._q = [];
      this._waiters = [];
      this._done = false;
      this._err = null;
      this._pulling = false;
      this._source = source;
      const self = this;
      this._ctrl = {
        enqueue: (c) => {
          self._q.push({ value: c });
          self._wake();
        },
        close: () => {
          self._done = true;
          self._wake();
        },
        error: (e) => {
          self._err = e;
          self._done = true;
          self._wake();
        },
      };
      if (source.start) {
        try {
          const r = source.start(this._ctrl);
          if (r && r.then)
            r.then(
              () => {},
              (e) => this._ctrl.error(e),
            );
        } catch (e) {
          this._ctrl.error(e);
        }
      }
    }
    _wake() {
      const w = this._waiters.splice(0);
      w.forEach((fn) => fn());
    }
    async _read() {
      for (;;) {
        if (this._q.length) return this._q.shift();
        if (this._err) throw this._err;
        if (this._done) return { done: true, value: undefined };
        if (this._source.pull && !this._pulling) {
          this._pulling = true;
          try {
            await this._source.pull(this._ctrl);
          } catch (e) {
            this._ctrl.error(e);
          }
          this._pulling = false;
        }
        if (!this._q.length && !this._done) await new Promise((r) => this._waiters.push(r));
      }
    }
    getReader() {
      return {
        read: () => this._read(),
        cancel: async () => {
          this._done = true;
          if (this._source.cancel) await this._source.cancel();
          this._wake();
        },
        releaseLock: () => {},
        closed: Promise.resolve(),
      };
    }
    async cancel() {
      this._done = true;
      if (this._source.cancel) await this._source.cancel();
      this._wake();
    }
    tee() {
      return [this, this];
    }
    [Symbol.asyncIterator]() {
      const self = this;
      return {
        next: async () => {
          const r = await self._read();
          return r.done ? { done: true, value: undefined } : { done: false, value: r.value };
        },
      };
    }
    values() {
      return this[Symbol.asyncIterator]();
    }
    pipeThrough(transform) {
      const reader = this.getReader();
      const writer = transform.writable.getWriter();
      (async () => {
        try {
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            await writer.write(value);
          }
          await writer.close();
        } catch {
          /* 下游关闭 */
        }
      })();
      return transform.readable;
    }
  }
  g.ReadableStream = ReadableStreamPolyfill;
  g.TransformStream = class TransformStream {
    constructor(transformer = {}) {
      const self = this;
      this._transformer = transformer;
      this._q = [];
      this._waiters = [];
      this._done = false;
      this.readable = new ReadableStreamPolyfill({ pull: async () => {} });
      this._readableCtrl = this.readable._ctrl;
      this.writable = {
        getWriter: () => ({
          write: async (chunk) => {
            if (self._transformer.transform) {
              await self._transformer.transform(chunk, {
                enqueue: (c) => self._readableCtrl.enqueue(c),
              });
            } else {
              self._readableCtrl.enqueue(chunk);
            }
            return undefined;
          },
          close: async () => {
            self._readableCtrl.close();
          },
          releaseLock: () => {},
        }),
      };
    }
  };
  g.WritableStream = class WritableStream {
    constructor() {}
  };
}

// 文本编解码流：ReadableStream 已在上面就绪后才能真正实现
if (typeof g.TextDecoderStream === "undefined") {
  g.TextDecoderStream = class TextDecoderStream {
    constructor(label = "utf-8") {
      const dec = new g.TextDecoder(label);
      this.encoding = label;
      this._ts = new g.TransformStream({
        transform: (chunk, ctrl) => {
          const text = dec.decode(chunk, { stream: true });
          if (text) ctrl.enqueue(text);
        },
      });
      this.readable = this._ts.readable;
      this.writable = this._ts.writable;
    }
  };
}
if (typeof g.TextEncoderStream === "undefined") {
  g.TextEncoderStream = class TextEncoderStream {
    constructor() {
      const enc = new g.TextEncoder();
      this.encoding = "utf-8";
      this._ts = new g.TransformStream({
        transform: (chunk, ctrl) => ctrl.enqueue(enc.encode(String(chunk))),
      });
      this.readable = this._ts.readable;
      this.writable = this._ts.writable;
    }
  };
}

if (typeof g.Blob === "undefined") {
  g.Blob = class Blob {
    constructor(parts = [], opts = {}) {
      this._parts = parts;
      this.type = opts.type || "";
      this.size = parts.reduce((a, p) => a + (typeof p === "string" ? p.length : p.length || 0), 0);
    }
    async text() {
      return this._parts.map((p) => (typeof p === "string" ? p : "" + p)).join("");
    }
    async arrayBuffer() {
      return new g.TextEncoder().encode(await this.text()).buffer;
    }
  };
}
if (typeof g.FormData === "undefined") {
  g.FormData = class FormData {
    constructor() {
      this._p = [];
    }
    append(k, v) {
      this._p.push([k, v]);
    }
    set(k, v) {
      this._p = this._p.filter(([kk]) => kk !== k);
      this._p.push([k, v]);
    }
    entries() {
      return this._p[Symbol.iterator]();
    }
  };
}
if (typeof g.Request === "undefined") {
  g.Request = class Request {
    constructor(input, init = {}) {
      this.url = typeof input === "string" ? input : input.url;
      this.method = (init.method || "GET").toUpperCase();
      this.headers = new g.Headers(init.headers || {});
      this.body = init.body;
      this.signal = init.signal;
    }
  };
}
if (typeof g.Response === "undefined") {
  g.Response = class Response {
    constructor(body = null, init = {}) {
      this.status = init.status ?? 200;
      this.ok = this.status >= 200 && this.status < 300;
      this.statusText = init.statusText ?? "";
      this.headers = new g.Headers(init.headers || {});
      const isStream = body && typeof body.getReader === "function";
      this._stream = isStream ? body : null;
      this._body = isStream ? null : body;
    }
    async text() {
      if (!this._stream) return typeof this._body === "string" ? this._body : "";
      const reader = this._stream.getReader();
      const parts = [];
      let size = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        const bytes =
          value instanceof Uint8Array ? value : new g.TextEncoder().encode(String(value));
        parts.push(bytes);
        size += bytes.length;
      }
      const all = new Uint8Array(size);
      let off = 0;
      for (const p of parts) {
        all.set(p, off);
        off += p.length;
      }
      return new g.TextDecoder().decode(all);
    }
    async json() {
      return JSON.parse(await this.text());
    }
    get body() {
      if (this._stream) return this._stream;
      const text = typeof this._body === "string" ? this._body : "";
      return new g.ReadableStream({
        start(ctrl) {
          if (text) ctrl.enqueue(new g.TextEncoder().encode(text));
          ctrl.close();
        },
      });
    }
  };
}

// fetch：原型阶段由宿主注入 __nativeFetch（Swift URLSession）；没有就报明确错误
if (typeof g.fetch === "undefined") {
  g.fetch = async (input, init) => {
    if (typeof g.__nativeFetch === "function") return g.__nativeFetch(input, init);
    throw new Error("fetch 未注入：真实 App 中由 Swift(URLSession) 提供");
  };
}

if (typeof g.structuredClone === "undefined") {
  g.structuredClone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
}
if (typeof g.performance === "undefined") {
  g.performance = { now: () => Date.now(), timeOrigin: Date.now() };
}
if (typeof g.self === "undefined") g.self = g;
if (typeof g.window === "undefined") g.window = g;

// ── 宿主 glue ────────────────────────────────────────────────────────────────
// 把 Swift 注入的 __nativeFetchStream / __nativeDbQuery 包成 fetch 与 IDatabase 形状。

if (typeof g.__nativeFetchStream === "function") {
  g.__nativeFetch = function (input, init) {
    init = init || {};
    const url = typeof input === "string" ? input : input && input.url ? input.url : String(input);
    const method = String(init.method || (input && input.method) || "GET").toUpperCase();

    const headers = {};
    const rawHeaders = init.headers || (input && input.headers);
    if (rawHeaders) {
      if (typeof rawHeaders.forEach === "function")
        rawHeaders.forEach((value, key) => {
          headers[key] = value;
        });
      else Object.assign(headers, rawHeaders);
    }

    let body = "";
    if (typeof init.body === "string") body = init.body;
    else if (init.body != null) body = JSON.stringify(init.body);

    const taskId = "t" + Date.now() + Math.random().toString(36).slice(2);
    const encoder = new TextEncoder();
    let controller = null;
    const stream = new ReadableStream({
      start(c) {
        controller = c;
      },
      cancel() {
        __nativeAbort(taskId);
      },
    });

    return new Promise((resolve, reject) => {
      let settled = false;
      __nativeFetchStream(
        url,
        method,
        JSON.stringify(headers),
        body,
        taskId,
        (status, headersJson) => {
          settled = true;
          resolve(
            new Response(stream, {
              status: status || 200,
              headers: JSON.parse(headersJson || "{}"),
            }),
          );
        },
        (chunk) => {
          if (controller) controller.enqueue(encoder.encode(chunk));
        },
        (error) => {
          if (error) {
            if (settled) {
              if (controller) controller.error(new Error(error));
            } else reject(new Error(error));
          } else if (controller) {
            controller.close();
          }
        },
      );

      const signal = init.signal || (input && input.signal);
      if (signal && typeof signal.addEventListener === "function") {
        signal.addEventListener("abort", () => __nativeAbort(taskId));
      }
    });
  };
}

if (typeof g.__nativeDbQuery === "function") {
  g.__hostDb = {
    // 默认库（":memory:"）；真实数据走 app-bootstrap 里的 platform.loadDatabase(path)
    query: (sql, params) =>
      JSON.parse(__nativeDbQuery(":memory:", String(sql), JSON.stringify(params || []))),
  };
}

// base64：JavaScriptCore 没有 btoa/atob，宿主文件读写用它搬运二进制
if (typeof g.__b64 === "undefined") {
  const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const INDEX = {};
  for (let i = 0; i < ALPHABET.length; i++) INDEX[ALPHABET[i]] = i;

  g.__b64 = {
    encode(bytes) {
      let out = "";
      for (let i = 0; i < bytes.length; i += 3) {
        const b0 = bytes[i];
        const b1 = i + 1 < bytes.length ? bytes[i + 1] : undefined;
        const b2 = i + 2 < bytes.length ? bytes[i + 2] : undefined;
        out += ALPHABET[b0 >> 2];
        out += ALPHABET[((b0 & 3) << 4) | (b1 === undefined ? 0 : b1 >> 4)];
        out +=
          b1 === undefined ? "=" : ALPHABET[((b1 & 15) << 2) | (b2 === undefined ? 0 : b2 >> 6)];
        out += b2 === undefined ? "=" : ALPHABET[b2 & 63];
      }
      return out;
    },
    decode(text) {
      const clean = String(text).replace(/[^A-Za-z0-9+/]/g, "");
      const bytes = [];
      for (let i = 0; i < clean.length; i += 4) {
        const c0 = INDEX[clean[i]];
        const c1 = INDEX[clean[i + 1]];
        const c2 = INDEX[clean[i + 2]];
        const c3 = INDEX[clean[i + 3]];
        bytes.push((c0 << 2) | (c1 >> 4));
        if (c2 !== undefined) bytes.push(((c1 & 15) << 4) | (c2 >> 2));
        if (c3 !== undefined) bytes.push(((c2 & 3) << 6) | c3);
      }
      return new Uint8Array(bytes);
    },
  };
}

// atob / btoa：JavaScriptCore 也没有这两个浏览器全局。核心包里有依赖（beautiful-mermaid 的
// entities）会先探 atob，没有就退回 Buffer —— JSC 同样没有 Buffer，整个包会在加载时就抛
// ReferenceError，所以这两个必须补上。
if (typeof g.atob === "undefined") {
  g.atob = (text) => {
    const bytes = g.__b64.decode(text);
    let out = "";
    for (let i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
    return out;
  };
}
if (typeof g.btoa === "undefined") {
  g.btoa = (text) => {
    const str = String(text);
    const bytes = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) bytes[i] = str.charCodeAt(i) & 0xff;
    return g.__b64.encode(bytes);
  };
}

// crypto：core 的 generateId() 要 crypto.getRandomValues（JSC 里没有原生 crypto）。
// 随机数优先用宿主（Swift / Security.SecRandomCopyBytes）给的字节。
if (typeof g.crypto === "undefined") {
  const randomBytes = (length) => {
    if (typeof g.__nativeRandomBytes === "function") {
      // 宿主返回 {"bytes":[…]}
      return Uint8Array.from(JSON.parse(__nativeRandomBytes(length)).bytes || []);
    }
    const fallback = new Uint8Array(length);
    for (let i = 0; i < length; i++) fallback[i] = Math.floor(Math.random() * 256);
    return fallback;
  };

  g.crypto = {
    getRandomValues(array) {
      const bytes = randomBytes(array.length);
      for (let i = 0; i < array.length; i++) array[i] = bytes[i];
      return array;
    },
    randomUUID() {
      const bytes = randomBytes(16);
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    },
    // core 的 epub 导出 / 校验路径要 SHA-256；书灯目前不跑那些路径，
    // 这里给一个明确报错的兜底，别静默。
    subtle: {
      digest: async () => {
        throw new Error("crypto.subtle 在书灯宿主里没有实现（文件摘要走 __nativeFileDigest）");
      },
    },
  };
}
