/* سند: الاتصال بقاعدة البيانات المشتركة (Supabase).
   يعطي التطبيق نفس واجهة قاعدة البيانات التي يستعملها داخل Claude
   (doc / collection / get / set / update / delete / onSnapshot)، فوق دوال supabase.sql.
   إذا كان config.js فارغًا يعمل التطبيق بالأمثلة على الجهاز فقط. */
(function () {
  "use strict";
  window.SANAD_PLATFORM = "web";
  var cfg = window.SANAD_CONFIG || {};
  var BASE = String(cfg.url || "").trim().replace(/\/+$/, "").replace(/\/rest\/v1$/, "");
  var APIKEY = String(cfg.key || "").trim();
  if (!/^https:\/\/[^\s\/]+$/.test(BASE) && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(BASE)) return;
  if (APIKEY.length < 20 || !window.fetch || !window.crypto || !crypto.getRandomValues) return;
  window.SANAD_CLOUD = true;

  var LIMIT = 400;
  var MSG = {
    offline: "تعذر الاتصال. تأكد من الإنترنت وحاول مرة ثانية.",
    server: "حدث خطأ في الخادم. حاول بعد قليل.",
    setup: "قاعدة البيانات غير مجهزة بعد (شغّل كود الإعداد في Supabase).",
    auth: "مفتاح قاعدة البيانات غير صحيح.",
    full: "اكتمل العدد لهذا الطلب.",
    closed: "هذا الطلب مغلق.",
    forbidden: "لا تملك صلاحية لهذا الإجراء.",
    not_found: "الطلب لم يعد موجودًا.",
    too_big: "حجم البيانات أكبر من المسموح.",
    rate_limit: "أرسلت كثيرًا في وقت قصير. حاول بعد قليل.",
    bad_key: "حدث خطأ في هوية الجهاز. حدّث الصفحة.",
    bad_path: "حدث خطأ في البيانات.",
    bad_data: "حدث خطأ في البيانات.",
  };
  function fail(code, msg) { var e = new Error(msg); e.code = code; return e; }

  // ---------- this device ----------
  function load(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function store(k, v) { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) { /* private mode */ } }
  function hex(b) { var s = ""; for (var i = 0; i < b.length; i++) s += (b[i] < 16 ? "0" : "") + b[i].toString(16); return s; }
  var DEVICE = "sanad.device.v1", PROFILE_CACHE = "sanad.profile.cache.v1";
  var KEY = load(DEVICE);
  if (!/^[0-9a-f]{64}$/.test(KEY || "")) { var rb = new Uint8Array(32); crypto.getRandomValues(rb); KEY = hex(rb); store(DEVICE, KEY); }
  var UID = null;

  // ---------- HTTP ----------
  var withAuth = /^eyJ/.test(APIKEY); // legacy anon keys are JWTs; publishable keys go in `apikey` only
  async function rpc(fn, args) {
    for (var attempt = 0; attempt < 2; attempt++) {
      var res, text, ctl = typeof AbortController === "function" ? new AbortController() : null;
      var timer = ctl ? setTimeout(function () { ctl.abort(); }, 20000) : null;
      try {
        var h = { "Content-Type": "application/json", "apikey": APIKEY };
        if (withAuth) h.Authorization = "Bearer " + APIKEY;
        res = await fetch(BASE + "/rest/v1/rpc/" + fn, { method: "POST", headers: h, body: JSON.stringify(args), cache: "no-store", credentials: "omit", signal: ctl ? ctl.signal : undefined });
        text = await res.text();
      } catch (e) { throw fail("unavailable", MSG.offline); }
      finally { clearTimeout(timer); }
      var body = null;
      if (text) { try { body = JSON.parse(text); } catch (e) { body = undefined; } }
      if (res.ok) return body === undefined ? null : body;
      var m = body && typeof body.message === "string" ? body.message : "";
      if ((res.status === 401 || res.status === 403) && attempt === 0 && m.indexOf("sanad:") !== 0) { withAuth = !withAuth; continue; }
      throw toError(res.status, body);
    }
  }
  function toError(status, body) {
    var m = body && typeof body.message === "string" ? body.message : "";
    if (m.indexOf("sanad:") === 0) {
      var k = m.slice(6);
      return fail(k === "not_found" ? "not-found" : k === "forbidden" ? "permission-denied" : k, MSG[k] || MSG.server);
    }
    if ((body && body.code === "PGRST202") || status === 404) return fail("failed-precondition", MSG.setup);
    if (status === 401 || status === 403) return fail("permission-denied", MSG.auth);
    if (status === 408 || status === 429 || status >= 500 || !status) return fail("unavailable", MSG.server);
    return fail("unknown", MSG.server);
  }

  var ready = (async function () {
    try {
      if (crypto.subtle && typeof TextEncoder === "function") {
        UID = "u_" + hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(KEY)))).slice(0, 20);
        return UID;
      }
    } catch (e) { /* not a secure page: ask the server */ }
    var r = await rpc("sanad_hello", { p_key: KEY });
    if (!r || !r.uid) throw fail("unavailable", MSG.offline);
    UID = r.uid;
    return UID;
  })();
  ready.catch(function () { /* the app falls back to examples */ });

  // ---------- helpers ----------
  function parentOf(p) { return p.slice(0, p.lastIndexOf("/")); }
  function lastSeg(p) { return p.slice(p.lastIndexOf("/") + 1); }
  function clone(v) { return v == null ? v : JSON.parse(JSON.stringify(v)); }
  function newId() {
    var a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", b = new Uint8Array(20), s = "";
    crypto.getRandomValues(b);
    for (var i = 0; i < b.length; i++) s += a[b[i] % 62];
    return s;
  }
  function isProfile(path) { return !!UID && path === "data/users/" + UID + "/profile"; }
  function cacheProfile(data) { store(PROFILE_CACHE, data ? JSON.stringify({ uid: UID, data: data }) : null); }
  function cachedProfile() {
    try { var c = JSON.parse(load(PROFILE_CACHE) || "null"); return c && c.uid === UID ? c.data : null; } catch (e) { return null; }
  }
  function docSnap(id, exists, data) {
    return { id: id, exists: exists, data: function () { return exists ? clone(data) : undefined; }, metadata: { fromCache: false, hasPendingWrites: false } };
  }

  // ---------- collections kept in sync by polling ----------
  var colls = {};
  function pollMs(coll) { return coll === "help_requests" ? 6000 : /\/(messages|live)$/.test(coll) ? 3000 : 15000; }
  function newState(coll) { return { coll: coll, docs: new Map(), tomb: new Map(), cursor: null, loaded: false, listeners: new Set(), timer: null, inflight: null, failed: 0, errored: false }; }

  function applyRow(st, row) {
    var cur = st.docs.get(row.path), dead = st.tomb.get(row.path);
    if (row.t && cur && cur.t && cur.t > row.t) return false;      // older than what we hold
    if (dead && !(row.t && row.t > dead)) return false;             // we already saw it deleted
    if (row.deleted) {
      st.tomb.set(row.path, row.t || "~");
      if (!cur) return false;
      st.docs.delete(row.path);
      return true;
    }
    if (cur && row.t && cur.t === row.t) return false;
    st.docs.set(row.path, { data: row.data, t: row.t || "" });
    return true;
  }
  function pull(st, full) {
    if (st.inflight) return st.inflight;
    var initial = full || !st.loaded;
    st.inflight = rpc("sanad_pull", { p_key: KEY, p_coll: st.coll, p_since: initial ? null : st.cursor, p_limit: LIMIT }).then(function (res) {
      var rows = (res && Array.isArray(res.rows)) ? res.rows : [], changed = false, maxT = "";
      rows.forEach(function (r) { if (r.t > maxT) maxT = r.t; });
      if (initial) {
        var before = st.docs, next = new Map();
        st.docs = next;
        rows.forEach(function (r) { if (!r.deleted) applyRow(st, r); });
        changed = !st.loaded || before.size !== next.size;
        if (!changed) next.forEach(function (v, k) { var o = before.get(k); if (!o || o.t !== v.t) changed = true; });
      } else {
        rows.forEach(function (r) { if (applyRow(st, r)) changed = true; });
      }
      st.cursor = (!initial && rows.length >= LIMIT) ? maxT : ((res && res.now) || maxT || st.cursor);
      st.loaded = true;
      return changed;
    });
    var done = function () { st.inflight = null; };
    st.inflight.then(done, done);
    return st.inflight;
  }
  function compare(order) {
    var f = order.f, dir = order.dir === "desc" ? -1 : 1;
    return function (a, b) {
      var x = a.data ? a.data[f] : undefined, y = b.data ? b.data[f] : undefined;
      if (x === y || (x == null && y == null)) return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return (x > y ? 1 : -1) * dir;
    };
  }
  function snapshot(st, q) {
    var list = [];
    st.docs.forEach(function (v, path) { list.push({ id: lastSeg(path), data: v.data }); });
    list.sort(q.order ? compare(q.order) : function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; });
    if (q.lim) list = list.slice(0, q.lim);
    var docs = list.map(function (d) { return docSnap(d.id, true, d.data); });
    return { docs: docs, size: docs.length, empty: !docs.length, forEach: function (fn) { docs.forEach(fn); }, docChanges: function () { return []; }, metadata: { fromCache: false, hasPendingWrites: false } };
  }
  function emit(st) {
    st.listeners.forEach(function (l) { try { l.next(snapshot(st, l.q)); } catch (e) { console.error(e); } });
  }
  function live(st) { return colls[st.coll] === st && st.listeners.size > 0; }
  function tick(st, full) {
    clearTimeout(st.timer); st.timer = null;
    if (!live(st)) return;
    if (document.hidden && st.loaded && !full) { st.timer = setTimeout(function () { tick(st); }, pollMs(st.coll)); return; }
    pull(st, full).then(function (changed) {
      if (!live(st)) return;
      st.failed = 0;
      if (changed || st.errored) { st.errored = false; emit(st); }
      st.timer = setTimeout(function () { tick(st); }, pollMs(st.coll));
    }, function (err) {
      if (!live(st)) return;
      st.failed++;
      if (!st.errored && (!st.loaded || st.failed >= 3)) {
        st.errored = true;
        st.listeners.forEach(function (l) { try { if (l.error) l.error(err); } catch (e) { /* ignore */ } });
      }
      st.timer = setTimeout(function () { tick(st); }, Math.min(60000, pollMs(st.coll) * Math.pow(2, Math.min(st.failed, 4))));
    });
  }
  var hiddenAt = 0;
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) { hiddenAt = Date.now(); return; }
    var long = hiddenAt && Date.now() - hiddenAt > 5 * 60e3;
    hiddenAt = 0;
    Object.keys(colls).forEach(function (k) { if (colls[k].listeners.size) tick(colls[k], long); });
  });
  window.addEventListener("online", function () {
    Object.keys(colls).forEach(function (k) { if (colls[k].listeners.size) tick(colls[k]); });
  });

  // a write the server confirmed: show it right away in any list we keep
  function local(row) {
    if (!row || !row.path) return;
    var st = colls[parentOf(row.path)];
    if (!st || !st.loaded) return;
    if (applyRow(st, row)) setTimeout(function () { if (colls[st.coll] === st) emit(st); }, 0);
  }

  // ---------- the database interface ----------
  function docRef(path) {
    var id = lastSeg(path);
    return {
      id: id, path: path,
      get: async function () {
        var row;
        try { row = await rpc("sanad_get", { p_key: KEY, p_path: path }); }
        catch (e) {
          if (e.code === "unavailable" && isProfile(path)) { var c = cachedProfile(); if (c) return docSnap(id, true, c); }
          throw e;
        }
        var exists = !!(row && !row.deleted);
        if (isProfile(path)) cacheProfile(exists ? row.data : null);
        local(row || { path: path, deleted: true, t: "" });
        return docSnap(id, exists, exists ? row.data : undefined);
      },
      set: async function (data) {
        var row = await rpc("sanad_set", { p_key: KEY, p_path: path, p_data: clone(data == null ? {} : data) });
        if (isProfile(path)) cacheProfile(row && row.data);
        local(row);
      },
      update: async function (patch) {
        var row = await rpc("sanad_merge", { p_key: KEY, p_path: path, p_patch: clone(patch == null ? {} : patch) });
        if (isProfile(path)) cacheProfile(row && row.data);
        local(row);
      },
      delete: async function () {
        var row = await rpc("sanad_delete", { p_key: KEY, p_path: path });
        if (isProfile(path)) cacheProfile(null);
        local(row || { path: path, deleted: true, t: "" });
      },
      onSnapshot: function (next, error) {
        if (next && typeof next === "object") { error = next.error; next = next.next; }
        var stopped = false, last = null, timer = null, ref = this;
        (function loop() {
          ref.get().then(function (s) {
            if (stopped) return;
            var key = JSON.stringify([s.exists, s.data()]);
            if (key !== last) { last = key; next(s); }
          }, function (e) { if (!stopped && error) error(e); }).then(function () { if (!stopped) timer = setTimeout(loop, 10000); });
        })();
        return function () { stopped = true; clearTimeout(timer); };
      },
      collection: function (sub) { return query(path + "/" + sub); },
    };
  }
  function query(coll, order, lim) {
    var q = { order: order || null, lim: lim || 0 };
    return {
      path: coll, id: lastSeg(coll),
      orderBy: function (f, dir) { return query(coll, { f: f, dir: dir || "asc" }, lim); },
      limit: function (n) { return query(coll, order, n); },
      where: function () { return this; },
      doc: function (id) { return docRef(coll + "/" + (id || newId())); },
      add: async function (data) { var r = docRef(coll + "/" + newId()); await r.set(data); return r; },
      get: async function () {
        var st = colls[coll];
        if (st && st.loaded) { if (await pull(st)) emit(st); return snapshot(st, q); }
        var tmp = newState(coll);
        await pull(tmp, true);
        return snapshot(tmp, q);
      },
      onSnapshot: function (next, error) {
        if (next && typeof next === "object") { error = next.error; next = next.next; }
        var st = colls[coll] || (colls[coll] = newState(coll));
        var l = { q: q, next: next, error: error };
        st.listeners.add(l);
        if (st.loaded) setTimeout(function () { if (st.listeners.has(l)) l.next(snapshot(st, q)); }, 0);
        if (st.listeners.size === 1) tick(st);
        return function () {
          st.listeners.delete(l);
          if (!st.listeners.size) { clearTimeout(st.timer); if (colls[coll] === st) delete colls[coll]; }
        };
      },
    };
  }
  var db = Object.freeze({ doc: docRef, collection: function (p) { return query(p); } });
  var user = Object.freeze({
    id: async function () { return ready; },
    isOwner: async function () { return false; },
    canEdit: async function () { return true; },
    can: async function () { return true; },
    me: async function () { return { id: await ready, name: "", isOwner: false, canEdit: true }; },
  });
  window.claude = { use: async function (name) { await ready; return name === "db" ? db : name === "user" ? user : null; } };
})();
