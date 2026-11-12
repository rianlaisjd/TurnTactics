-- Release upgrade 2 of 5. Run AFTER 020_accounts_invites.sql. Safe to re-run.
-- Push infrastructure: preferences, device subscriptions, an authoritative outbox written only by
-- game/chat functions, and service-only claim/report functions used by the tt-push Edge Function.
begin;

create or replace function public.tt_notify_defaults() returns jsonb
language sql immutable set search_path='' as $$
  select jsonb_build_object('income', true, 'dm', true, 'eliminated', true,
    'movement', false, 'rules', false, 'match', false, 'bonus', false, 'review', false)
$$;

create table if not exists public.tt_notify_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  prefs jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default clock_timestamp()
);
create table if not exists public.tt_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique check (length(endpoint) <= 1000),
  p256dh text not null, auth_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  last_success timestamptz, failures int not null default 0
);
create index if not exists tt_push_subscriptions_user on public.tt_push_subscriptions(user_id);
-- Events are addressed to a ROOM SEAT (-1 = host), never to an account: the owner is resolved
-- at delivery time, so a recovered-away identity stops receiving that seat's updates.
create table if not exists public.tt_outbox (
  id bigint generated always as identity primary key,
  room text not null references public.tt_rooms(code) on delete cascade,
  seat int not null check (seat between -1 and 19),
  category text not null, dedupe text not null,
  created_at timestamptz not null default clock_timestamp(),
  status text not null default 'queued' check (status in ('queued','sending','sent','dropped')),
  claimed_at timestamptz, attempts int not null default 0,
  unique (room, seat, dedupe)
);
create index if not exists tt_outbox_status on public.tt_outbox(status, id);
alter table public.tt_notify_prefs enable row level security;
alter table public.tt_push_subscriptions enable row level security;
alter table public.tt_outbox enable row level security;
revoke all on public.tt_notify_prefs, public.tt_push_subscriptions, public.tt_outbox from public, anon, authenticated;
revoke all on sequence public.tt_outbox_id_seq from public, anon, authenticated;

-- Internal: queue one event. Duplicate (room, seat, dedupe) is ignored, so re-running a step is harmless.
create or replace function public.tt_notify(p_room text, p_seat int, p_category text, p_dedupe text) returns void
language sql security definer set search_path='' as $$
  insert into public.tt_outbox(room, seat, category, dedupe) values (p_room, p_seat, p_category, p_dedupe)
  on conflict (room, seat, dedupe) do nothing
$$;
-- Internal: queue for every real seat (optionally living only / with host / except one seat).
create or replace function public.tt_notify_room(p_room text, p_state jsonb, p_category text, p_dedupe text,
  p_host boolean default true, p_living_only boolean default false, p_except int default null) returns void
language sql security definer set search_path='' as $$
  insert into public.tt_outbox(room, seat, category, dedupe)
  select p_room, seat, p_category, p_dedupe from (
    select (value->>'id')::int as seat from jsonb_array_elements(p_state->'players')
     where not coalesce((value->>'isTestSeat')::boolean, false)
       and (not p_living_only or (value->>'alive')::boolean)
    union all select -1 where p_host
  ) x where p_except is null or seat <> p_except
  on conflict (room, seat, dedupe) do nothing
$$;

-- Only well-known browser push services over HTTPS: the sender must never fetch arbitrary URLs.
create or replace function public.tt_push_endpoint_ok(p_endpoint text) returns boolean
language sql immutable set search_path='' as $$
  select p_endpoint is not null and length(p_endpoint) <= 1000 and p_endpoint ~
   '^https://([a-z0-9-]+\.)*(fcm\.googleapis\.com|push\.services\.mozilla\.com|notify\.windows\.com|push\.apple\.com)/[A-Za-z0-9_./:%=?&~+-]+$'
$$;

create or replace function public.tt_push_prefs() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare stored jsonb; n int;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select prefs into stored from public.tt_notify_prefs where user_id = auth.uid();
  select count(*) into n from public.tt_push_subscriptions where user_id = auth.uid();
  return jsonb_build_object('prefs', public.tt_notify_defaults() || coalesce(stored, '{}'::jsonb), 'devices', n,
    'quietHours', jsonb_build_object('start', 22, 'end', 8, 'timezone', 'America/Los_Angeles'));
end;$$;

create or replace function public.tt_push_prefs_save(p_prefs jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare k text; v jsonb; clean jsonb := '{}'::jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_prefs is null or jsonb_typeof(p_prefs) <> 'object' then raise exception 'Invalid preferences'; end if;
  for k, v in select key, value from jsonb_each(p_prefs) loop
    if not (public.tt_notify_defaults() ? k) or jsonb_typeof(v) <> 'boolean' then raise exception 'Invalid preferences'; end if;
    clean := clean || jsonb_build_object(k, v);
  end loop;
  insert into public.tt_notify_prefs(user_id, prefs) values (auth.uid(), clean)
  on conflict (user_id) do update set prefs = public.tt_notify_prefs.prefs || excluded.prefs, updated_at = clock_timestamp();
  return public.tt_push_prefs();
end;$$;

create or replace function public.tt_push_subscribe(p_endpoint text, p_p256dh text, p_auth text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if not public.tt_push_endpoint_ok(p_endpoint) then raise exception 'This browser''s push service is not supported'; end if;
  if coalesce(p_p256dh,'') !~ '^[A-Za-z0-9_-]{40,200}$' or coalesce(p_auth,'') !~ '^[A-Za-z0-9_-]{16,60}$' then
    raise exception 'Invalid push subscription';
  end if;
  -- A device belongs to whoever subscribed it last: switching accounts moves it, never shares it.
  insert into public.tt_push_subscriptions(user_id, endpoint, p256dh, auth_key) values (auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh,
    auth_key = excluded.auth_key, failures = 0;
  delete from public.tt_push_subscriptions where user_id = auth.uid() and id not in (
    select id from public.tt_push_subscriptions where user_id = auth.uid() order by created_at desc limit 8);
  return public.tt_push_prefs();
end;$$;

create or replace function public.tt_push_unsubscribe(p_endpoint text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from public.tt_push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
  return public.tt_push_prefs();
end;$$;

-- Service only. Returns deliveries for the Edge Function and leases their events.
-- Enforces: quiet hours (22:00–08:00 Pacific → held, then one summary), preferences, current seat
-- ownership, coalescing per account, a five-attempt cap, and a 36-hour staleness limit.
create or replace function public.tt_push_claim(p_limit int default 200, p_now timestamptz default clock_timestamp()) returns jsonb
language plpgsql security definer set search_path='' as $$
declare local_hour int := extract(hour from p_now at time zone 'America/Los_Angeles')::int; result jsonb;
begin
  update public.tt_outbox set status = 'queued' where status = 'sending' and claimed_at < p_now - interval '5 minutes';
  update public.tt_outbox set status = 'dropped' where status = 'queued' and (attempts >= 5 or created_at < p_now - interval '36 hours');
  delete from public.tt_outbox where status in ('sent','dropped') and created_at < p_now - interval '3 days';
  if local_hour >= 22 or local_hour < 8 then return '[]'::jsonb; end if;

  if to_regclass('pg_temp.tt_claim') is not null then drop table pg_temp.tt_claim; end if;
  create temporary table tt_claim on commit drop as
  select o.id, o.room, o.category,
    case when o.seat = -1 then r.host::text
         else (select a->>'uid' from jsonb_array_elements(r.state->'players') a where (a->>'id')::int = o.seat) end as owner
  from (select * from public.tt_outbox where status = 'queued' order by id limit greatest(1, least(coalesce(p_limit, 200), 1000))
        for update skip locked) o
  join public.tt_rooms r on r.code = o.room;

  -- Drop what must not be delivered: no real owner, category switched off, or no device.
  update public.tt_outbox o set status = 'dropped' from tt_claim c
   where o.id = c.id and (
     c.owner is null or c.owner !~ '^[0-9a-f-]{36}$'
     or not coalesce(((public.tt_notify_defaults() || coalesce(
          (select prefs from public.tt_notify_prefs p where p.user_id::text = c.owner), '{}'::jsonb)) ->> c.category)::boolean, false)
     or not exists(select 1 from public.tt_push_subscriptions s where s.user_id::text = c.owner));
  delete from tt_claim c using public.tt_outbox o where o.id = c.id and o.status = 'dropped';
  update public.tt_outbox o set status = 'sending', claimed_at = p_now, attempts = attempts + 1 from tt_claim c where o.id = c.id;

  -- Generic text only: no sender, message, resource or room detail reaches the lock screen.
  select coalesce(jsonb_agg(jsonb_build_object(
    'subscription', jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth_key),
    'ids', g.ids,
    'payload', jsonb_build_object('title', 'Turn Tactics',
      'body', case when g.n = 1 then 'You have a new update.' else 'You have ' || g.n || ' new updates.' end,
      'tag', 'turn-tactics',
      'url', case when g.rooms = 1 then './online.html?room=' || g.room || '&view=' ||
                    case when g.n = 1 and g.category = 'dm' then 'chat'
                         when g.n = 1 and g.category in ('rules','review') then 'council' else 'field' end
                  else './online.html' end))), '[]'::jsonb)
  into result
  from (select owner, jsonb_agg(id order by id) as ids, count(*) as n, count(distinct room) as rooms,
               min(room) as room, min(category) as category from tt_claim group by owner) g
  join public.tt_push_subscriptions s on s.user_id::text = g.owner;
  return result;
end;$$;

-- Service only. p_results: [{"subscription": uuid, "ids": [bigint...], "status": "ok"|"gone"|"retry"}]
create or replace function public.tt_push_report(p_results jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare item jsonb;
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' then return; end if;
  for item in select value from jsonb_array_elements(p_results) where value->>'status' <> 'ok' loop
    if item->>'status' = 'gone' then
      delete from public.tt_push_subscriptions where id = (item->>'subscription')::uuid;
    else
      update public.tt_push_subscriptions set failures = failures + 1 where id = (item->>'subscription')::uuid;
      delete from public.tt_push_subscriptions where id = (item->>'subscription')::uuid and failures >= 10;
    end if;
    update public.tt_outbox set status = 'queued'
     where status = 'sending' and id in (select value::bigint from jsonb_array_elements_text(item->'ids'));
  end loop;
  -- Successes last: an event that reached any of the owner's devices is finished, never re-sent.
  for item in select value from jsonb_array_elements(p_results) where value->>'status' = 'ok' loop
    update public.tt_push_subscriptions set failures = 0, last_success = clock_timestamp() where id = (item->>'subscription')::uuid;
    update public.tt_outbox set status = 'sent'
     where status in ('sending','queued') and id in (select value::bigint from jsonb_array_elements_text(item->'ids'));
  end loop;
end;$$;

revoke all on function public.tt_notify_defaults(), public.tt_notify(text,int,text,text),
  public.tt_notify_room(text,jsonb,text,text,boolean,boolean,int), public.tt_push_endpoint_ok(text),
  public.tt_push_prefs(), public.tt_push_prefs_save(jsonb), public.tt_push_subscribe(text,text,text),
  public.tt_push_unsubscribe(text), public.tt_push_claim(int,timestamptz), public.tt_push_report(jsonb)
  from public, anon, authenticated;
grant execute on function public.tt_push_prefs(), public.tt_push_prefs_save(jsonb),
  public.tt_push_subscribe(text,text,text), public.tt_push_unsubscribe(text) to authenticated;
grant execute on function public.tt_push_claim(int,timestamptz), public.tt_push_report(jsonb) to service_role;
commit;
notify pgrst, 'reload schema';
