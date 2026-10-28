// سند: دالة إرسال الإشعارات إلى الجوالات (Web Push).
// تستدعيها قاعدة البيانات فقط بعد كل إشعار جديد، وتعطيها الأجهزة ونص الإشعار.
// الإنشاء: Supabase ← Edge Functions ← Deploy a new function ← Via Editor،
// والاسم sanad-push، ثم من صفحة الدالة أطفئ «Verify JWT with legacy secret».

// المفتاح العام نفسه الموجود في config.js (pushKey)، والمفتاح الخاص سرّي.
const VAPID_PUBLIC = "BO9UXMlz99gjquXLsxij3mw_bds9ML9p-nrVVb0Hmhp32Farba10pfYdP_OZdBMwU_T4-rXGqQyIsUaLbm6d5AA";
const VAPID_PRIVATE = Deno.env.get("SANAD_VAPID_PRIVATE") || "__SANAD_VAPID_PRIVATE__";
const SUBJECT = "https://abtkar2011-bot.github.io/Sanad/";

// خدمات الإشعارات المعروفة فقط (حتى لا تُستعمل الدالة لإرسال أي شيء لأي مكان)
const PUSH_HOSTS = [".googleapis.com", ".push.apple.com", ".mozilla.com", ".mozaws.net", ".notify.windows.com", ".push.services.mozilla.com"];
const TEST_HOST = Deno.env.get("SANAD_PUSH_TEST_HOST") || ""; // للاختبار المحلي فقط

const enc = new TextEncoder();

function b64u(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function unb64u(str) {
  let s = String(str || "").replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  while (s.length % 4) s += "=";
  const bin = atob(s), out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function concat(...parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}
async function hmac(key, data) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

// RFC 8291: تشفير نص الإشعار بمفتاحي الجهاز (p256dh و auth) بطريقة aes128gcm
export async function encryptPayload(payload, uaPublicB64, authB64, testing) {
  const uaPublic = unb64u(uaPublicB64), auth = unb64u(authB64);
  if (uaPublic.length !== 65 || auth.length < 16) throw new Error("bad_keys");
  const salt = testing && testing.salt ? unb64u(testing.salt) : crypto.getRandomValues(new Uint8Array(16));
  const eph = testing && testing.ephemeral ? testing.ephemeral : await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, eph.privateKey, 256));
  const prkKey = await hmac(auth, shared);
  const ikm = await hmac(prkKey, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic, new Uint8Array([1])));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, concat(enc.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, concat(enc.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))).slice(0, 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const body = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, key, concat(payload, new Uint8Array([2]))));
  const header = new Uint8Array(21);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, 4096);
  header[20] = 65;
  return concat(header, asPublic, body);
}

// RFC 8292: توقيع VAPID (ES256) يثبت أن الإشعار من سند
let signingKey = null;
async function vapidKey() {
  if (signingKey) return signingKey;
  const pub = unb64u(VAPID_PUBLIC);
  const jwk = { kty: "EC", crv: "P-256", x: b64u(pub.slice(1, 33)), y: b64u(pub.slice(33, 65)), d: VAPID_PRIVATE, ext: true };
  signingKey = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return signingKey;
}
const jwtCache = new Map();
async function vapidAuth(endpoint) {
  const aud = new URL(endpoint).origin;
  const now = Math.floor(Date.now() / 1000);
  const hit = jwtCache.get(aud);
  if (hit && hit.exp - now > 3600) return hit.value;
  const exp = now + 12 * 3600;
  const head = b64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = b64u(enc.encode(JSON.stringify({ aud, exp, sub: SUBJECT })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await vapidKey(), enc.encode(head + "." + claims)));
  const value = "vapid t=" + head + "." + claims + "." + b64u(sig) + ", k=" + VAPID_PUBLIC;
  jwtCache.set(aud, { exp, value });
  return value;
}

function allowed(endpoint) {
  let u;
  try { u = new URL(endpoint); } catch (e) { return false; }
  if (TEST_HOST && u.origin === TEST_HOST) return true;
  return u.protocol === "https:" && PUSH_HOSTS.some((h) => u.hostname.endsWith(h));
}

async function sendOne(m) {
  const ep = m && m.sub && m.sub.endpoint;
  const keys = (m && m.sub && m.sub.keys) || {};
  if (!ep || !allowed(ep)) return { endpoint: ep, status: 0, error: "endpoint" };
  const p = m.payload || {};
  const data = enc.encode(JSON.stringify({
    title: String(p.title || "سند").slice(0, 120), body: String(p.body || "").slice(0, 300),
    tag: String(p.tag || "").slice(0, 80), url: String(p.url || "./").slice(0, 200),
    kind: String(p.kind || ""), badge: typeof p.badge === "number" ? p.badge : undefined,
  }));
  let body;
  try { body = await encryptPayload(data, keys.p256dh, keys.auth); }
  catch (e) { return { endpoint: ep, status: 0, error: "keys" }; }
  const topic = String(p.tag || "").replace(/[^A-Za-z0-9_-]/g, "-").slice(0, 32);
  const headers = {
    "Authorization": await vapidAuth(ep),
    "Content-Encoding": "aes128gcm",
    "Content-Type": "application/octet-stream",
    "TTL": "86400",
    "Urgency": "high",
  };
  if (topic) headers["Topic"] = topic;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 8000);
  try {
    const res = await fetch(ep, { method: "POST", headers, body, signal: ctl.signal });
    await res.body?.cancel();
    return { endpoint: ep, status: res.status };
  } catch (e) {
    return { endpoint: ep, status: 0, error: "network" };
  } finally {
    clearTimeout(timer);
  }
}

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, apikey, authorization" };
function reply(obj, status) {
  return new Response(JSON.stringify(obj), { status: status || 200, headers: { ...CORS, "Content-Type": "application/json" } });
}

export async function handle(req) {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return reply({ ok: true, service: "sanad-push" });
  if (!VAPID_PRIVATE || VAPID_PRIVATE.startsWith("__")) return reply({ ok: false, error: "no_key" }, 500);
  let input;
  try { input = await req.json(); } catch (e) { return reply({ ok: false, error: "bad_json" }, 400); }
  const list = Array.isArray(input && input.messages) ? input.messages.slice(0, 500) : [];
  const results = [];
  for (let i = 0; i < list.length; i += 20) {
    results.push(...await Promise.all(list.slice(i, i + 20).map(sendOne)));
  }
  const sent = results.filter((r) => r.status >= 200 && r.status < 300).length;
  const gone = results.filter((r) => r.status === 404 || r.status === 410).map((r) => r.endpoint);
  return reply({ ok: true, sent, failed: results.length - sent, gone });
}

Deno.serve(handle);
