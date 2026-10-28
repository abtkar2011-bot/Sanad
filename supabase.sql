-- سند: إعداد قاعدة البيانات
-- الصق هذا الملف كاملًا في Supabase ← SQL Editor ← New query، ثم اضغط Run.
-- يجوز تشغيله أكثر من مرة.
--
-- كل البيانات في جدول واحد (sanad_docs). الموقع لا يصل للجدول مباشرة،
-- بل عن طريق الدوال أدناه فقط، وكل دالة تتحقق من صاحب الجهاز:
--   - الطلبات والرسائل الصوتية: يقرؤها الجميع، ويعدّلها صاحبها فقط.
--   - المتطوع يستطيع فقط إضافة نفسه أو سحب نفسه من الطلب.
--   - المحادثة والموقع المباشر: يراهما صاحب الطلب ومن قبله فقط.
--   - الحساب والبلاغ: لا يراهما إلا صاحبهما (وأنت من لوحة Supabase).

create table if not exists public.sanad_docs (
  path       text primary key,
  coll       text not null,
  owner      text not null,
  data       jsonb not null default '{}'::jsonb,
  deleted    boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default clock_timestamp()
);
create index if not exists sanad_docs_coll_t on public.sanad_docs (coll, updated_at);
create index if not exists sanad_docs_owner_t on public.sanad_docs (owner, created_at);
alter table public.sanad_docs enable row level security;
revoke all on public.sanad_docs from public, anon, authenticated;

create or replace function public.sanad_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end $$;
create or replace trigger sanad_touch before update on public.sanad_docs
  for each row execute function public.sanad_touch();

-- كل جهاز يحمل مفتاحًا سريًا؛ المعرّف العلني مشتق منه.
create or replace function public.sanad_uid(p_key text) returns text
language sql immutable set search_path = '' as $$
  select case when p_key ~ '^[0-9a-f]{40,128}$'
    then 'u_' || left(encode(sha256(convert_to(p_key, 'UTF8')), 'hex'), 20) end
$$;

create or replace function public.sanad_kind(p text) returns text
language sql immutable set search_path = '' as $$
  select case
    when p ~ '^help_requests/[A-Za-z0-9_-]{1,64}$' then 'request'
    when p ~ '^help_requests/[A-Za-z0-9_-]{1,64}/messages/[A-Za-z0-9_-]{1,64}$' then 'message'
    when p ~ '^help_requests/[A-Za-z0-9_-]{1,64}/voice/clip$' then 'voice'
    when p ~ '^help_requests/[A-Za-z0-9_-]{1,64}/live/[A-Za-z0-9_-]{1,64}$' then 'live'
    when p ~ '^data/users/[A-Za-z0-9_-]{1,64}/profile$' then 'profile'
    when p ~ '^reports/[A-Za-z0-9_-]{1,64}$' then 'report'
  end
$$;

create or replace function public.sanad_max(k text) returns int
language sql immutable set search_path = '' as $$
  select case k when 'voice' then 300000 when 'report' then 40000 when 'request' then 8000
                when 'profile' then 3000 when 'live' then 400 else 1500 end
$$;

create or replace function public.sanad_ts(t timestamptz) returns text
language sql immutable set search_path = '' as $$
  select to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

create or replace function public.sanad_row(d public.sanad_docs) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('path', d.path, 'deleted', d.deleted, 't', public.sanad_ts(d.updated_at),
                            'data', case when d.deleted then null else d.data end)
$$;

create or replace function public.sanad_is_participant(p_req text, p_me text) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from public.sanad_docs r
    where r.path = p_req and not r.deleted
      and (r.owner = p_me
           or coalesce(r.data -> 'helpers', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('uid', p_me))))
$$;

create or replace function public.sanad_hello(p_key text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('uid', public.sanad_uid(p_key), 'now', public.sanad_ts(statement_timestamp()), 'v', 1)
$$;

create or replace function public.sanad_get(p_key text, p_path text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  me text := public.sanad_uid(p_key);
  k text := public.sanad_kind(p_path);
  d public.sanad_docs;
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  if k is null then raise exception 'sanad:bad_path'; end if;
  select * into d from public.sanad_docs where path = p_path;
  if not found or d.deleted then return null; end if;
  if k in ('message', 'live') and not public.sanad_is_participant(split_part(p_path, '/', 1) || '/' || split_part(p_path, '/', 2), me) then
    return null;
  end if;
  if k in ('profile', 'report') and d.owner <> me then return null; end if;
  return public.sanad_row(d);
end $$;

create or replace function public.sanad_pull(p_key text, p_coll text, p_since text default null, p_limit int default 400)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  me text := public.sanad_uid(p_key);
  lim int := least(greatest(coalesce(p_limit, 400), 1), 1000);
  priv boolean := false;
  since timestamptz;
  out_rows jsonb;
  now_t text := public.sanad_ts(statement_timestamp());
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  if p_coll = 'help_requests' or p_coll ~ '^help_requests/[A-Za-z0-9_-]{1,64}/voice$' then
    priv := false;
  elsif p_coll ~ '^help_requests/[A-Za-z0-9_-]{1,64}/(messages|live)$' then
    if not public.sanad_is_participant(split_part(p_coll, '/', 1) || '/' || split_part(p_coll, '/', 2), me) then
      return jsonb_build_object('now', now_t, 'rows', '[]'::jsonb);
    end if;
  elsif p_coll = 'reports' or p_coll ~ '^data/users/[A-Za-z0-9_-]{1,64}$' then
    priv := true;
  else
    raise exception 'sanad:bad_path';
  end if;
  if coalesce(p_since, '') <> '' then
    since := p_since::timestamptz - interval '3 seconds';
  end if;
  if since is null then
    select coalesce(jsonb_agg(public.sanad_row(x) order by x.updated_at desc), '[]'::jsonb) into out_rows
    from (select * from public.sanad_docs d
          where d.coll = p_coll and not d.deleted and d.updated_at > now() - interval '60 days'
            and (not priv or d.owner = me)
          order by d.updated_at desc limit lim) x;
  else
    select coalesce(jsonb_agg(public.sanad_row(x) order by x.updated_at), '[]'::jsonb) into out_rows
    from (select * from public.sanad_docs d
          where d.coll = p_coll and d.updated_at > since
            and (not priv or d.owner = me)
          order by d.updated_at limit lim) x;
  end if;
  return jsonb_build_object('now', now_t, 'rows', out_rows);
end $$;

create or replace function public.sanad_set(p_key text, p_path text, p_data jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  me text := public.sanad_uid(p_key);
  k text := public.sanad_kind(p_path);
  dat jsonb := coalesce(p_data, '{}'::jsonb);
  ppath text := split_part(p_path, '/', 1) || '/' || split_part(p_path, '/', 2);
  d public.sanad_docs;
  had boolean;
  pown text;
  n int;
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  if k is null then raise exception 'sanad:bad_path'; end if;
  if jsonb_typeof(dat) <> 'object' then raise exception 'sanad:bad_data'; end if;
  if octet_length(dat::text) > public.sanad_max(k) then raise exception 'sanad:too_big'; end if;
  select * into d from public.sanad_docs where path = p_path for update;
  had := found;
  if had and d.owner <> me then raise exception 'sanad:forbidden'; end if;
  if k = 'request' then
    dat := dat || jsonb_build_object('created_by', me);
    if not had then
      select count(*) into n from public.sanad_docs
      where owner = me and coll = 'help_requests' and created_at > now() - interval '1 day';
      if n >= 30 then raise exception 'sanad:rate_limit'; end if;
    end if;
  elsif k = 'message' then
    if not public.sanad_is_participant(ppath, me) then raise exception 'sanad:forbidden'; end if;
    select count(*) into n from public.sanad_docs
    where owner = me and coll like 'help\_requests/%/messages' and created_at > now() - interval '1 hour';
    if n >= 150 then raise exception 'sanad:rate_limit'; end if;
    dat := jsonb_build_object(
      'uid', me,
      'name', left(coalesce(dat ->> 'name', ''), 40),
      'text', left(coalesce(dat ->> 'text', ''), 300),
      'at', case when jsonb_typeof(dat -> 'at') = 'number' then dat -> 'at'
                 else to_jsonb(floor(extract(epoch from now()) * 1000)::bigint) end);
  elsif k = 'live' then
    -- where a helper or the person who asked is right now; only the two of them see it
    if not public.sanad_is_participant(ppath, me) or split_part(p_path, '/', 4) <> me then raise exception 'sanad:forbidden'; end if;
    if jsonb_typeof(dat -> 'lat') <> 'number' or jsonb_typeof(dat -> 'lng') <> 'number' then raise exception 'sanad:bad_data'; end if;
    dat := jsonb_build_object('lat', dat -> 'lat', 'lng', dat -> 'lng', 'acc', coalesce(dat -> 'acc', '0'::jsonb),
                              'at', coalesce(dat -> 'at', to_jsonb(floor(extract(epoch from now()) * 1000)::bigint)),
                              'name', left(coalesce(dat ->> 'name', ''), 40));
  elsif k = 'voice' then
    select owner into pown from public.sanad_docs where path = ppath and not deleted;
    if pown is not null and pown <> me then raise exception 'sanad:forbidden'; end if;
  elsif k = 'profile' then
    if split_part(p_path, '/', 3) <> me then raise exception 'sanad:forbidden'; end if;
  elsif k = 'report' then
    if split_part(p_path, '/', 2) <> me then raise exception 'sanad:forbidden'; end if;
  end if;
  insert into public.sanad_docs (path, coll, owner, data, deleted)
  values (p_path, regexp_replace(p_path, '/[^/]+$', ''), me, dat, false)
  on conflict (path) do update set data = excluded.data, deleted = false
  returning * into d;
  return public.sanad_row(d);
end $$;

create or replace function public.sanad_merge(p_key text, p_path text, p_patch jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  me text := public.sanad_uid(p_key);
  k text := public.sanad_kind(p_path);
  patch jsonb := coalesce(p_patch, '{}'::jsonb);
  d public.sanad_docs;
  cur jsonb;
  others jsonb;
  mine jsonb;
  existing jsonb;
  hs jsonb;
  cap int;
  newdata jsonb;
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  if k is null then raise exception 'sanad:bad_path'; end if;
  if jsonb_typeof(patch) <> 'object' then raise exception 'sanad:bad_data'; end if;
  select * into d from public.sanad_docs where path = p_path for update;
  if not found or d.deleted then raise exception 'sanad:not_found'; end if;
  if d.owner = me then
    if k = 'message' then raise exception 'sanad:forbidden'; end if;
    newdata := d.data || (patch - 'created_by' - 'helpers');
  elsif k = 'request' then
    -- someone else: they may only add or remove themselves as a helper,
    -- and once the help is done, rate the person they helped
    if not (patch ? 'helpers') then raise exception 'sanad:forbidden'; end if;
    cur := case when jsonb_typeof(d.data -> 'helpers') = 'array' then d.data -> 'helpers' else '[]'::jsonb end;
    select coalesce(jsonb_agg(e.h order by e.i), '[]'::jsonb) into others
    from jsonb_array_elements(cur) with ordinality as e(h, i) where e.h ->> 'uid' is distinct from me;
    select e.h into existing from jsonb_array_elements(cur) as e(h) where e.h ->> 'uid' = me limit 1;
    select e.h into mine
    from jsonb_array_elements(case when jsonb_typeof(patch -> 'helpers') = 'array' then patch -> 'helpers' else '[]'::jsonb end) as e(h)
    where e.h ->> 'uid' = me limit 1;
    if d.data ->> 'status' = 'done' then
      if existing is null or mine is null or jsonb_typeof(mine -> 'rate') <> 'number' then raise exception 'sanad:closed'; end if;
      select coalesce(jsonb_agg(case when e.h ->> 'uid' = me
               then e.h || jsonb_build_object('rate', least(5, greatest(1, round((mine ->> 'rate')::numeric))))
               else e.h end order by e.i), '[]'::jsonb) into hs
      from jsonb_array_elements(cur) with ordinality as e(h, i);
    elsif mine is null then
      hs := others;
    elsif existing is not null then
      hs := cur;
    else
      cap := case when d.data ->> 'timing' = 'dated'
                  then greatest(1, case when d.data ->> 'needed' ~ '^[0-9]{1,4}(\.[0-9]+)?$'
                                        then floor((d.data ->> 'needed')::numeric)::int else 1 end)
                  else 1 end;
      if jsonb_array_length(others) >= cap then raise exception 'sanad:full'; end if;
      hs := others || jsonb_build_array(jsonb_build_object(
        'uid', me,
        'name', left(coalesce(mine ->> 'name', ''), 40),
        'at', case when jsonb_typeof(mine -> 'at') = 'number' then mine -> 'at'
                   else to_jsonb(floor(extract(epoch from now()) * 1000)::bigint) end));
    end if;
    newdata := d.data || jsonb_build_object('helpers', hs);
    if coalesce(d.data ->> 'timing', '') <> 'dated' and d.data ->> 'status' is distinct from 'done' then
      newdata := newdata || jsonb_build_object('status', case when jsonb_array_length(hs) > 0 then 'accepted' else 'open' end);
    end if;
  else
    raise exception 'sanad:forbidden';
  end if;
  if octet_length(newdata::text) > public.sanad_max(k) then raise exception 'sanad:too_big'; end if;
  update public.sanad_docs set data = newdata where path = p_path returning * into d;
  if k = 'request' and newdata ->> 'status' = 'done' then
    -- the help is over: stop showing where people are
    update public.sanad_docs set deleted = true, data = '{}'::jsonb
    where starts_with(path, p_path || '/live/') and not deleted;
  end if;
  return public.sanad_row(d);
end $$;

create or replace function public.sanad_delete(p_key text, p_path text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  me text := public.sanad_uid(p_key);
  k text := public.sanad_kind(p_path);
  d public.sanad_docs;
  pown text;
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  if k is null then raise exception 'sanad:bad_path'; end if;
  select * into d from public.sanad_docs where path = p_path for update;
  if not found or d.deleted then return null; end if;
  if d.owner <> me then
    if k not in ('message', 'voice') then raise exception 'sanad:forbidden'; end if;
    select owner into pown from public.sanad_docs
    where path = split_part(p_path, '/', 1) || '/' || split_part(p_path, '/', 2);
    if pown is distinct from me then raise exception 'sanad:forbidden'; end if;
  end if;
  update public.sanad_docs set deleted = true, data = '{}'::jsonb where path = p_path returning * into d;
  if k = 'request' then
    update public.sanad_docs set deleted = true, data = '{}'::jsonb
    where starts_with(path, p_path || '/') and not deleted;
  end if;
  return public.sanad_row(d);
end $$;

-- الموقع يستدعي هذه الدوال فقط
revoke all on function public.sanad_touch(), public.sanad_uid(text), public.sanad_kind(text),
  public.sanad_max(text), public.sanad_ts(timestamptz), public.sanad_row(public.sanad_docs),
  public.sanad_is_participant(text, text) from public, anon, authenticated;
revoke all on function public.sanad_hello(text), public.sanad_get(text, text),
  public.sanad_pull(text, text, text, int), public.sanad_set(text, text, jsonb),
  public.sanad_merge(text, text, jsonb), public.sanad_delete(text, text) from public;
grant execute on function public.sanad_hello(text), public.sanad_get(text, text),
  public.sanad_pull(text, text, text, int), public.sanad_set(text, text, jsonb),
  public.sanad_merge(text, text, jsonb), public.sanad_delete(text, text) to anon, authenticated;

-- ===== لوحة المطورين (admin.html) =====
-- الحسابات في جدول خاص؛ كلمات المرور محفوظة مشفّرة (bcrypt) ولا تظهر في الموقع.
-- بعد 5 محاولات خاطئة يُقفل الحساب 15 دقيقة.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.sanad_admins (
  username     text primary key,
  pass_hash    text not null,
  fails        int not null default 0,
  locked_until timestamptz
);
alter table public.sanad_admins enable row level security;
revoke all on public.sanad_admins from public, anon, authenticated;

create or replace function public.sanad_admin_auth(p_user text, p_pass text) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare a public.sanad_admins;
begin
  select * into a from public.sanad_admins where username = lower(trim(coalesce(p_user, ''))) for update;
  if not found then return 'denied'; end if;
  if a.locked_until is not null and a.locked_until > now() then return 'locked'; end if;
  if extensions.crypt(coalesce(p_pass, ''), a.pass_hash) = a.pass_hash then
    update public.sanad_admins set fails = 0, locked_until = null where username = a.username;
    return 'ok';
  end if;
  update public.sanad_admins
  set fails = case when a.fails + 1 >= 5 then 0 else a.fails + 1 end,
      locked_until = case when a.fails + 1 >= 5 then now() + interval '15 minutes' else null end
  where username = a.username;
  return case when a.fails + 1 >= 5 then 'locked' else 'denied' end;
end $$;

create or replace function public.sanad_admin_data(p_user text, p_pass text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare st text := public.sanad_admin_auth(p_user, p_pass);
begin
  if st <> 'ok' then return jsonb_build_object('ok', false, 'error', st); end if;
  return jsonb_build_object(
    'ok', true,
    'now', public.sanad_ts(now()),
    'reports', (select coalesce(jsonb_agg(jsonb_build_object('path', d.path, 'reporter', d.owner, 'items', coalesce(d.data -> 'items', '[]'::jsonb))
                  order by d.updated_at desc), '[]'::jsonb)
                from public.sanad_docs d where d.coll = 'reports' and not d.deleted),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', split_part(d.path, '/', 2), 'owner', d.owner, 'data', d.data)
                   order by d.created_at desc), '[]'::jsonb)
                 from (select * from public.sanad_docs x where x.coll = 'help_requests' and not x.deleted
                       and x.created_at > now() - interval '120 days' order by x.created_at desc limit 2000) d),
    'users', (select coalesce(jsonb_object_agg(d.owner, jsonb_build_object(
                'full_name', d.data ->> 'full_name', 'phone', d.data ->> 'phone', 'wilayat', d.data ->> 'wilayat',
                'age_group', d.data ->> 'age_group', 'gender', d.data ->> 'gender')), '{}'::jsonb)
              from public.sanad_docs d where d.coll like 'data/users/%' and not d.deleted)
  );
end $$;

create or replace function public.sanad_admin_delete_request(p_user text, p_pass text, p_id text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare st text := public.sanad_admin_auth(p_user, p_pass);
begin
  if st <> 'ok' then return jsonb_build_object('ok', false, 'error', st); end if;
  if coalesce(p_id, '') !~ '^[A-Za-z0-9_-]{1,64}$' then return jsonb_build_object('ok', false, 'error', 'bad_id'); end if;
  update public.sanad_docs set deleted = true, data = '{}'::jsonb
  where (path = 'help_requests/' || p_id or starts_with(path, 'help_requests/' || p_id || '/')) and not deleted;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.sanad_admin_dismiss(p_user text, p_pass text, p_report text, p_at bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare st text := public.sanad_admin_auth(p_user, p_pass);
begin
  if st <> 'ok' then return jsonb_build_object('ok', false, 'error', st); end if;
  update public.sanad_docs
  set data = jsonb_set(data, '{items}', coalesce((select jsonb_agg(e.v order by e.i)
               from jsonb_array_elements(coalesce(data -> 'items', '[]'::jsonb)) with ordinality as e(v, i)
               where (e.v ->> 'at') is distinct from p_at::text), '[]'::jsonb))
  where path = p_report and coll = 'reports' and not deleted;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.sanad_admin_auth(text, text) from public, anon, authenticated;
revoke all on function public.sanad_admin_data(text, text), public.sanad_admin_delete_request(text, text, text),
  public.sanad_admin_dismiss(text, text, text, bigint) from public;
grant execute on function public.sanad_admin_data(text, text), public.sanad_admin_delete_request(text, text, text),
  public.sanad_admin_dismiss(text, text, text, bigint) to anon, authenticated;

-- ===== الإشعارات =====
-- كل حدث يهمّك يُحفظ هنا لك وحدك: أحد قبل طلبك أو انسحب، رسالة جديدة، طلب جديد قريب منك،
-- انتهى الطلب أو أُلغي، أو بدأ أحد يشارك موقعه معك. التقييمات لا تُرسل كإشعارات.
-- إذا فعّل الشخص الإشعارات في جواله، ترسلها قاعدة البيانات للدالة sanad-push (Edge Functions).
do $$ begin
  create extension if not exists pg_net with schema extensions;
exception when others then
  raise notice 'pg_net: %', sqlerrm;
end $$;

create sequence if not exists public.sanad_notifs_seq;
create table if not exists public.sanad_notifs (
  id         bigint generated always as identity primary key,
  seq        bigint not null default nextval('public.sanad_notifs_seq'),
  uid        text not null,
  kind       text not null,
  req        text,
  actor      text,
  title      text not null,
  body       text not null default '',
  created_at timestamptz not null default clock_timestamp(),
  read_at    timestamptz
);
create index if not exists sanad_notifs_uid_seq on public.sanad_notifs (uid, seq);
create index if not exists sanad_notifs_created on public.sanad_notifs (created_at);
alter table public.sanad_notifs enable row level security;
revoke all on public.sanad_notifs from public, anon, authenticated;
revoke all on sequence public.sanad_notifs_seq from public, anon, authenticated;

-- أجهزة فعّلت الإشعارات (Web Push)
create table if not exists public.sanad_push_subs (
  endpoint   text primary key,
  uid        text not null,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists sanad_push_subs_uid on public.sanad_push_subs (uid);
alter table public.sanad_push_subs enable row level security;
revoke all on public.sanad_push_subs from public, anon, authenticated;

create table if not exists public.sanad_push_log (
  req_id     bigint primary key,
  created_at timestamptz not null default now()
);
alter table public.sanad_push_log enable row level security;
revoke all on public.sanad_push_log from public, anon, authenticated;

-- عنوان دالة الإرسال في مشروعك، والمفتاح العام (نفس الموجود في config.js)
create or replace function public.sanad_push_url() returns text
language sql immutable set search_path = '' as $$
  select 'https://bdbiznxphhxbidnasavc.supabase.co/functions/v1/sanad-push'
$$;
create or replace function public.sanad_push_apikey() returns text
language sql immutable set search_path = '' as $$
  select 'sb_publishable_XxCjHNbXvVnG6BogY60NHg_sOGxTCki'
$$;

create or replace function public.sanad_notif_row(n public.sanad_notifs) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('id', n.id, 'seq', n.seq, 'kind', n.kind, 'req', n.req, 'title', n.title, 'body', n.body,
                            'at', floor(extract(epoch from n.created_at) * 1000)::bigint, 'read', n.read_at is not null)
$$;

-- يحذف من القائمة أجهزة ألغت الإشعارات (حسب رد دالة الإرسال)
create or replace function public.sanad_push_gc() returns void
language plpgsql volatile security definer set search_path = '' as $$
declare r record; n int;
begin
  for r in select l.req_id, h.status_code, h.content
           from public.sanad_push_log l join net._http_response h on h.id = l.req_id loop
    if r.status_code = 200 and r.content is not null then
      begin
        with gone as (select jsonb_array_elements_text(r.content::jsonb -> 'gone') as ep)
        , removed as (delete from public.sanad_push_subs s using gone g where s.endpoint = g.ep returning 1)
        select count(*) into n from removed;
      exception when others then null;
      end;
    end if;
  end loop;
  with old as (delete from public.sanad_push_log l
               where l.created_at < now() - interval '1 day'
                  or exists (select 1 from net._http_response h where h.id = l.req_id)
               returning 1)
  select count(*) into n from old;
exception when others then null;
end $$;

create or replace function public.sanad_push(p_ids bigint[]) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare msgs jsonb; rid bigint;
begin
  select jsonb_agg(jsonb_build_object(
           'sub', jsonb_build_object('endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth)),
           'payload', jsonb_build_object(
             'title', n.title, 'body', n.body, 'kind', n.kind,
             'tag', n.kind || ':' || coalesce(n.req, n.id::text),
             'url', case when n.req is not null then './?open=' || n.req else './?notifs=1' end,
             'badge', (select count(*) from public.sanad_notifs u where u.uid = n.uid and u.read_at is null))))
    into msgs
  from public.sanad_notifs n join public.sanad_push_subs s on s.uid = n.uid
  where n.id = any(p_ids);
  if msgs is null then return; end if;
  perform public.sanad_push_gc();
  begin
    rid := net.http_post(
      url := public.sanad_push_url(),
      body := jsonb_build_object('messages', msgs),
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', public.sanad_push_apikey()),
      timeout_milliseconds := 10000);
    insert into public.sanad_push_log (req_id) values (rid) on conflict do nothing;
  exception when others then
    raise warning 'sanad push: %', sqlerrm;
  end;
end $$;

-- يحفظ الإشعارات ويرسلها. رسائل المحادثة على نفس الطلب تُجمع في إشعار واحد حتى تقرأه.
create or replace function public.sanad_emit(p_items jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare it jsonb; nid bigint; ids bigint[] := '{}';
begin
  for it in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    continue when coalesce(it ->> 'uid', '') = '' or it ->> 'uid' = coalesce(it ->> 'actor', '');
    nid := null;
    if it ->> 'kind' = 'msg' then
      update public.sanad_notifs
      set title = left(it ->> 'title', 120), body = left(coalesce(it ->> 'body', ''), 200), actor = it ->> 'actor',
          created_at = clock_timestamp(), seq = nextval('public.sanad_notifs_seq')
      where id = (select n.id from public.sanad_notifs n
                  where n.uid = it ->> 'uid' and n.kind = 'msg' and n.req is not distinct from it ->> 'req' and n.read_at is null
                  order by n.seq desc limit 1)
      returning id into nid;
    end if;
    if nid is null then
      insert into public.sanad_notifs (uid, kind, req, actor, title, body)
      values (it ->> 'uid', it ->> 'kind', it ->> 'req', it ->> 'actor', left(it ->> 'title', 120), left(coalesce(it ->> 'body', ''), 200))
      returning id into nid;
    end if;
    ids := ids || nid;
  end loop;
  if cardinality(ids) = 0 then return; end if;
  if random() < 0.02 then delete from public.sanad_notifs where created_at < now() - interval '60 days'; end if;
  perform public.sanad_push(ids);
end $$;

create or replace function public.sanad_sec_label(s text) returns text
language sql immutable set search_path = '' as $$
  select case s when 'road' then 'على الطريق' when 'social' then 'الحياة الاجتماعية'
                when 'occasion' then 'الأفراح والأتراح' when 'elderly' then 'كبار السن وذوو الاحتياجات' else 'سند' end
$$;

-- يقرر من يستحق إشعارًا عند كل تغيير. أي خطأ هنا لا يوقف حفظ البيانات.
create or replace function public.sanad_on_doc() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  k text := public.sanad_kind(new.path);
  rid text := split_part(new.path, '/', 2);
  alive_old boolean := tg_op = 'UPDATE' and not old.deleted;
  alive_new boolean := not new.deleted;
  r public.sanad_docs;
  d jsonb; od jsonb;
  oh jsonb; nh jsonb; h jsonb;
  snippet text; who text; ttl text;
  dated boolean; rlat float8; rlng float8;
  items jsonb := '[]'::jsonb;
begin
  if k = 'request' then
    d := case when alive_new then new.data else old.data end;
    snippet := public.sanad_sec_label(d ->> 'section') || ': ' || left(coalesce(d ->> 'details', ''), 90);
    who := coalesce(nullif(d ->> 'display_name', ''), 'صاحب الطلب');
    nh := case when jsonb_typeof(new.data -> 'helpers') = 'array' then new.data -> 'helpers' else '[]'::jsonb end;
    oh := case when tg_op = 'UPDATE' and jsonb_typeof(old.data -> 'helpers') = 'array' then old.data -> 'helpers' else '[]'::jsonb end;

    if alive_new and not alive_old and coalesce(d ->> 'status', 'open') <> 'done' then
      -- طلب جديد: لمن حوله (١٠ كم)، أو لأهل الولاية إذا كان له موعد
      dated := d ->> 'timing' = 'dated';
      rlat := case when jsonb_typeof(d -> 'lat') = 'number' then (d ->> 'lat')::float8 end;
      rlng := case when jsonb_typeof(d -> 'lng') = 'number' then (d ->> 'lng')::float8 end;
      ttl := case when dated then 'مبادرة جديدة في ولايتك'
                  when d ->> 'request_type' = 'offer' then 'عرض مساعدة قريب منك'
                  else 'طلب مساعدة قريب منك' end;
      select coalesce(jsonb_agg(jsonb_build_object('uid', p.owner, 'kind', 'near', 'req', rid, 'actor', new.owner,
                                                   'title', ttl, 'body', snippet)), '[]'::jsonb)
        into items
      from (
        select x.owner, x.km from (
          select u.owner,
                 case when dated then 0
                      when jsonb_typeof(u.data -> 'lat') = 'number' and jsonb_typeof(u.data -> 'lng') = 'number' and rlat is not null and rlng is not null
                      then 2 * 6371 * asin(least(1, sqrt(
                             power(sin(radians((u.data ->> 'lat')::float8 - rlat) / 2), 2)
                             + cos(radians(rlat)) * cos(radians((u.data ->> 'lat')::float8))
                               * power(sin(radians((u.data ->> 'lng')::float8 - rlng) / 2), 2))))
                 end as km
          from public.sanad_docs u
          where u.coll like 'data/users/%' and u.path like '%/profile' and not u.deleted and u.owner <> new.owner
            and u.data -> 'notify_near' is distinct from 'false'::jsonb
            and coalesce(u.data ->> 'age_group', '') <> '59+'
            and (coalesce(u.data ->> 'age_group', '') <> 'u18' or dated)
            and (d -> 'prefer_female' is distinct from 'true'::jsonb or u.data ->> 'gender' = 'female')
            and (not dated or u.data ->> 'wilayat' = d ->> 'wilayat')
        ) x
        where x.km is not null and x.km <= 10
        order by x.km limit 300
      ) p;

    elsif alive_old and alive_new then
      -- من انضم
      for h in select value from jsonb_array_elements(nh) loop
        if not oh @> jsonb_build_array(jsonb_build_object('uid', h ->> 'uid')) then
          items := items || jsonb_build_object('uid', new.owner, 'kind', 'join', 'req', rid, 'actor', h ->> 'uid',
            'title', coalesce(nullif(h ->> 'name', ''), 'متطوع') || case when d ->> 'request_type' = 'offer' then ' انضم إلى عرضك' else ' قبل طلبك' end,
            'body', snippet);
        end if;
      end loop;
      -- من انسحب
      if coalesce(d ->> 'status', '') <> 'done' then
        for h in select value from jsonb_array_elements(oh) loop
          if not nh @> jsonb_build_array(jsonb_build_object('uid', h ->> 'uid')) then
            items := items || jsonb_build_object('uid', new.owner, 'kind', 'leave', 'req', rid, 'actor', h ->> 'uid',
              'title', coalesce(nullif(h ->> 'name', ''), 'متطوع') || ' انسحب من طلبك', 'body', snippet);
          end if;
        end loop;
      end if;
      -- انتهت المساعدة
      if coalesce(old.data ->> 'status', '') <> 'done' and new.data ->> 'status' = 'done' then
        for h in select value from jsonb_array_elements(nh) loop
          items := items || jsonb_build_object('uid', h ->> 'uid', 'kind', 'done', 'req', rid, 'actor', new.owner,
            'title', case when d ->> 'request_type' = 'offer' then 'تمت المساعدة' else 'تمت المساعدة، شكرًا لك' end,
            'body', 'أغلق ' || who || ' الطلب، وتقدر تقيّم تجربتك الآن.');
        end loop;
      end if;

    elsif alive_old and not alive_new and coalesce(old.data ->> 'status', '') <> 'done' then
      -- أُلغي الطلب
      for h in select value from jsonb_array_elements(oh) loop
        items := items || jsonb_build_object('uid', h ->> 'uid', 'kind', 'cancel', 'req', rid, 'actor', old.owner,
          'title', 'أُلغي طلب ' || who, 'body', snippet);
      end loop;
    end if;

  elsif k in ('message', 'live') and alive_new and not alive_old then
    select * into r from public.sanad_docs where path = 'help_requests/' || rid and not deleted;
    if found then
      od := case when jsonb_typeof(r.data -> 'helpers') = 'array' then r.data -> 'helpers' else '[]'::jsonb end;
      ttl := coalesce(nullif(new.data ->> 'name', ''), 'مستخدم');
      for who in select r.owner union select e ->> 'uid' from jsonb_array_elements(od) e loop
        continue when who is null or who = new.owner;
        if k = 'message' then
          items := items || jsonb_build_object('uid', who, 'kind', 'msg', 'req', rid, 'actor', new.owner,
            'title', 'رسالة من ' || ttl, 'body', left(coalesce(new.data ->> 'text', ''), 140));
        else
          items := items || jsonb_build_object('uid', who, 'kind', 'live', 'req', rid, 'actor', new.owner,
            'title', ttl || ' يشارك موقعه المباشر معك', 'body', 'افتح الطلب وشوف وين وصل.');
        end if;
      end loop;
    end if;
  end if;

  if jsonb_array_length(items) > 0 then perform public.sanad_emit(items); end if;
  return null;
exception when others then
  raise warning 'sanad notify: %', sqlerrm;
  return null;
end $$;
create or replace trigger sanad_notify after insert or update on public.sanad_docs
  for each row execute function public.sanad_on_doc();

-- ما يستدعيه الموقع
create or replace function public.sanad_notifs(p_key text, p_after bigint default 0) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare me text := public.sanad_uid(p_key); items jsonb; unread int; mx bigint;
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  if coalesce(p_after, 0) <= 0 then
    select coalesce(jsonb_agg(public.sanad_notif_row(n) order by n.seq desc), '[]'::jsonb) into items
    from (select * from public.sanad_notifs where uid = me order by seq desc limit 60) n;
  else
    select coalesce(jsonb_agg(public.sanad_notif_row(n) order by n.seq), '[]'::jsonb) into items
    from (select * from public.sanad_notifs where uid = me and seq > p_after order by seq limit 100) n;
  end if;
  select count(*) filter (where read_at is null), coalesce(max(seq), 0) into unread, mx from public.sanad_notifs where uid = me;
  return jsonb_build_object('items', items, 'unread', unread, 'seq', mx);
end $$;

create or replace function public.sanad_notifs_read(p_key text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me text := public.sanad_uid(p_key);
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  update public.sanad_notifs set read_at = now() where uid = me and read_at is null;
  return jsonb_build_object('unread', 0);
end $$;

create or replace function public.sanad_push_save(p_key text, p_sub jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  me text := public.sanad_uid(p_key);
  ep text := p_sub ->> 'endpoint';
  pk text := p_sub #>> '{keys,p256dh}';
  au text := p_sub #>> '{keys,auth}';
  n int;
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  if ep is null or ep !~ '^https://[A-Za-z0-9.-]+(:[0-9]+)?/' or length(ep) > 1000
     or coalesce(pk, '') !~ '^[A-Za-z0-9_=+/-]{80,100}$' or coalesce(au, '') !~ '^[A-Za-z0-9_=+/-]{16,32}$' then
    raise exception 'sanad:bad_data';
  end if;
  insert into public.sanad_push_subs (endpoint, uid, p256dh, auth) values (ep, me, pk, au)
  on conflict (endpoint) do update set uid = excluded.uid, p256dh = excluded.p256dh, auth = excluded.auth, updated_at = now();
  -- خمسة أجهزة لكل شخص على الأكثر
  with extra as (delete from public.sanad_push_subs x
                 where x.uid = me and x.endpoint not in (select s.endpoint from public.sanad_push_subs s where s.uid = me order by s.updated_at desc limit 5)
                 returning 1)
  select count(*) into n from extra;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.sanad_push_remove(p_key text, p_endpoint text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me text := public.sanad_uid(p_key); n int;
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  with gone as (delete from public.sanad_push_subs x where x.uid = me and x.endpoint = p_endpoint returning 1)
  select count(*) into n from gone;
  return jsonb_build_object('ok', true);
end $$;

-- ===== نقل الحساب لجهاز ثاني =====
-- التطبيق المثبّت على الشاشة الرئيسية في الآيفون والآيباد لا يرى بيانات المتصفح،
-- فينقل الشخص حسابه برمز من ٨ خانات صالح لنصف ساعة ولمرة واحدة.
create table if not exists public.sanad_transfers (
  code       text primary key,
  dev_key    text not null,
  uid        text not null,
  expires_at timestamptz not null
);
alter table public.sanad_transfers enable row level security;
revoke all on public.sanad_transfers from public, anon, authenticated;
create table if not exists public.sanad_transfer_fails (at timestamptz not null default now());
create index if not exists sanad_transfer_fails_at on public.sanad_transfer_fails (at);
alter table public.sanad_transfer_fails enable row level security;
revoke all on public.sanad_transfer_fails from public, anon, authenticated;

create or replace function public.sanad_transfer_create(p_key text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  me text := public.sanad_uid(p_key);
  alpha text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  c text; b bytea; i int; n int;
begin
  if me is null then raise exception 'sanad:bad_key'; end if;
  with old as (delete from public.sanad_transfers x where x.expires_at < now() or x.uid = me returning 1)
  select count(*) into n from old;
  loop
    b := extensions.gen_random_bytes(8); c := '';
    for i in 0..7 loop c := c || substr(alpha, 1 + (get_byte(b, i) % 31), 1); end loop;
    exit when not exists (select 1 from public.sanad_transfers t where t.code = c);
  end loop;
  insert into public.sanad_transfers (code, dev_key, uid, expires_at) values (c, p_key, me, now() + interval '30 minutes');
  return jsonb_build_object('code', c, 'expires', floor(extract(epoch from now() + interval '30 minutes') * 1000)::bigint);
end $$;

create or replace function public.sanad_transfer_claim(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  c text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  k text; n int;
begin
  if (select count(*) from public.sanad_transfer_fails f where f.at > now() - interval '10 minutes') >= 300 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  with used as (delete from public.sanad_transfers x where x.code = c and x.expires_at > now() returning x.dev_key)
  select max(dev_key) into k from used;
  if k is null then
    insert into public.sanad_transfer_fails default values;
    with old as (delete from public.sanad_transfer_fails f where f.at < now() - interval '1 hour' returning 1)
    select count(*) into n from old;
    return jsonb_build_object('ok', false, 'error', 'bad_code');
  end if;
  return jsonb_build_object('ok', true, 'key', k);
end $$;

revoke all on function public.sanad_push_url(), public.sanad_push_apikey(), public.sanad_notif_row(public.sanad_notifs),
  public.sanad_push_gc(), public.sanad_push(bigint[]), public.sanad_emit(jsonb), public.sanad_sec_label(text),
  public.sanad_on_doc() from public, anon, authenticated;
revoke all on function public.sanad_notifs(text, bigint), public.sanad_notifs_read(text), public.sanad_push_save(text, jsonb),
  public.sanad_push_remove(text, text), public.sanad_transfer_create(text), public.sanad_transfer_claim(text) from public;
grant execute on function public.sanad_notifs(text, bigint), public.sanad_notifs_read(text), public.sanad_push_save(text, jsonb),
  public.sanad_push_remove(text, text), public.sanad_transfer_create(text), public.sanad_transfer_claim(text) to anon, authenticated;

notify pgrst, 'reload schema';

select 'تم تجهيز قاعدة بيانات سند ✓' as "النتيجة";
