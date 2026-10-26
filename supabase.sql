-- سند: إعداد قاعدة البيانات
-- الصق هذا الملف كاملًا في Supabase ← SQL Editor ← New query، ثم اضغط Run.
-- يجوز تشغيله أكثر من مرة.
--
-- كل البيانات في جدول واحد (sanad_docs). الموقع لا يصل للجدول مباشرة،
-- بل عن طريق الدوال أدناه فقط، وكل دالة تتحقق من صاحب الجهاز:
--   - الطلبات والرسائل الصوتية: يقرؤها الجميع، ويعدّلها صاحبها فقط.
--   - المتطوع يستطيع فقط إضافة نفسه أو سحب نفسه من الطلب.
--   - المحادثة: يقرؤها ويكتب فيها صاحب الطلب ومن قبله فقط.
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
    when p ~ '^data/users/[A-Za-z0-9_-]{1,64}/profile$' then 'profile'
    when p ~ '^reports/[A-Za-z0-9_-]{1,64}$' then 'report'
  end
$$;

create or replace function public.sanad_max(k text) returns int
language sql immutable set search_path = '' as $$
  select case k when 'voice' then 300000 when 'report' then 40000 when 'request' then 8000
                when 'profile' then 3000 else 1500 end
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
  if k = 'message' and not public.sanad_is_participant(split_part(p_path, '/', 1) || '/' || split_part(p_path, '/', 2), me) then
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
  elsif p_coll ~ '^help_requests/[A-Za-z0-9_-]{1,64}/messages$' then
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
    newdata := d.data || (patch - 'created_by');
  elsif k = 'request' then
    -- someone else: they may only add or remove themselves as a helper
    if d.data ->> 'status' = 'done' then raise exception 'sanad:closed'; end if;
    if not (patch ? 'helpers') then raise exception 'sanad:forbidden'; end if;
    cur := case when jsonb_typeof(d.data -> 'helpers') = 'array' then d.data -> 'helpers' else '[]'::jsonb end;
    select coalesce(jsonb_agg(e.h order by e.i), '[]'::jsonb) into others
    from jsonb_array_elements(cur) with ordinality as e(h, i) where e.h ->> 'uid' is distinct from me;
    select e.h into existing from jsonb_array_elements(cur) as e(h) where e.h ->> 'uid' = me limit 1;
    select e.h into mine
    from jsonb_array_elements(case when jsonb_typeof(patch -> 'helpers') = 'array' then patch -> 'helpers' else '[]'::jsonb end) as e(h)
    where e.h ->> 'uid' = me limit 1;
    if mine is null then
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
    if coalesce(d.data ->> 'timing', '') <> 'dated' then
      newdata := newdata || jsonb_build_object('status', case when jsonb_array_length(hs) > 0 then 'accepted' else 'open' end);
    end if;
  else
    raise exception 'sanad:forbidden';
  end if;
  if octet_length(newdata::text) > public.sanad_max(k) then raise exception 'sanad:too_big'; end if;
  update public.sanad_docs set data = newdata where path = p_path returning * into d;
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

notify pgrst, 'reload schema';

select 'تم تجهيز قاعدة بيانات سند ✓' as "النتيجة";
