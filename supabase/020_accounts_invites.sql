-- Release upgrade 1 of 5. Run AFTER 018_chat.sql. Safe to re-run. No room, seat or message is reset.
-- Adds: account profiles (username + display name), a service-only username sign-in gate,
-- six-character invitation aliases for rooms, and join-attempt abuse protection.
begin;

-- ---------- Account profiles ----------
create table if not exists public.tt_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (length(display_name) between 1 and 24),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create unique index if not exists tt_profiles_username on public.tt_profiles(username);
alter table public.tt_profiles enable row level security;
revoke all on public.tt_profiles from public, anon, authenticated;

-- True only for a signed-in, non-anonymous Supabase Auth user.
create or replace function public.tt_is_account() returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and exists(
    select 1 from auth.users u where u.id = auth.uid() and not coalesce(u.is_anonymous, false))
$$;

-- Display names that could be mistaken for the referee, the room channel or a placeholder.
create or replace function public.tt_name_reserved(p_name text) returns boolean
language sql immutable set search_path='' as $$
  select lower(regexp_replace(coalesce(p_name,''), '[^A-Za-z]', '', 'g'))
           in ('host','referee','hostreferee','roomchat','turntactics','system','admin','moderator')
      or lower(trim(coalesce(p_name,''))) like 'test seat%'
$$;

-- Returns the caller's account display name, or raises when they may not host/join.
create or replace function public.tt_require_account() returns text
language plpgsql stable security definer set search_path='' as $$
declare shown text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if not public.tt_is_account() then
    raise exception 'Create an account or sign in to host or join a game';
  end if;
  select display_name into shown from public.tt_profiles where user_id = auth.uid();
  if shown is null then raise exception 'Choose a username and display name first'; end if;
  return shown;
end;$$;

create or replace function public.tt_profile() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare p public.tt_profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into p from public.tt_profiles where user_id = auth.uid();
  return jsonb_build_object('account', public.tt_is_account(), 'hasProfile', p.user_id is not null,
    'username', p.username, 'displayName', p.display_name);
end;$$;

create or replace function public.tt_profile_save(p_username text, p_display text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uname text := lower(trim(coalesce(p_username,''))); shown text := trim(coalesce(p_display,''));
begin
  if not public.tt_is_account() then raise exception 'Create an account or sign in first'; end if;
  if uname !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Usernames use 3–20 letters, numbers or underscores';
  end if;
  if length(shown) not between 1 and 24 then raise exception 'Use a display name of 1–24 characters'; end if;
  if public.tt_name_reserved(shown) or public.tt_name_reserved(uname) then
    raise exception 'That name is reserved. Choose another';
  end if;
  begin
    insert into public.tt_profiles(user_id, username, display_name) values (auth.uid(), uname, shown)
    on conflict (user_id) do update
      set username = excluded.username, display_name = excluded.display_name, updated_at = clock_timestamp();
  exception when unique_violation then
    raise exception 'That username is taken. Choose another';
  end;
  return public.tt_profile();
end;$$;

-- ---------- Username sign-in gate (service role only; called by the tt-login Edge Function) ----------
-- Clients never receive an email address: the function resolves and signs in server-side.
create table if not exists public.tt_login_attempts (
  id bigint generated always as identity primary key,
  key text not null, at timestamptz not null default clock_timestamp()
);
create index if not exists tt_login_attempts_key_at on public.tt_login_attempts(key, at);
alter table public.tt_login_attempts enable row level security;
revoke all on public.tt_login_attempts from public, anon, authenticated;

create or replace function public.tt_login_gate(p_identifier text, p_ip text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ident text := lower(trim(coalesce(p_identifier,'')));
  k_id text; k_ip text; n_id int; n_ip int; found_email text;
begin
  if length(ident) not between 3 and 254 then return jsonb_build_object('allowed', true, 'email', null); end if;
  k_id := 'u:' || encode(sha256(convert_to(ident, 'UTF8')), 'hex');
  k_ip := 'i:' || encode(sha256(convert_to(coalesce(p_ip,'unknown'), 'UTF8')), 'hex');
  delete from public.tt_login_attempts where at < clock_timestamp() - interval '1 day';
  select count(*) filter (where key = k_id), count(*) filter (where key = k_ip) into n_id, n_ip
    from public.tt_login_attempts
    where key in (k_id, k_ip) and at > clock_timestamp() - interval '15 minutes';
  if n_id >= 10 or n_ip >= 40 then return jsonb_build_object('allowed', false, 'email', null); end if;
  insert into public.tt_login_attempts(key) values (k_id), (k_ip);
  if position('@' in ident) > 0 then found_email := ident;
  else
    select u.email into found_email from public.tt_profiles p join auth.users u on u.id = p.user_id
      where p.username = ident;
  end if;
  return jsonb_build_object('allowed', true, 'email', found_email);
end;$$;

-- ---------- Six-character invitations ----------
alter table public.tt_rooms add column if not exists invite text;
create unique index if not exists tt_rooms_invite on public.tt_rooms(invite);
alter table public.tt_rooms drop constraint if exists tt_rooms_invite_format;
alter table public.tt_rooms add constraint tt_rooms_invite_format
  check (invite is null or invite ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$');

-- 31 unambiguous symbols (no I, L, O, 0, 1). Uniform via rejection sampling over the
-- CSPRNG bytes of gen_random_uuid(); the two partly-fixed UUID bytes are skipped.
create or replace function public.tt_invite_candidate() returns text
language plpgsql volatile set search_path='' as $$
declare alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; made text := ''; b bytea; i int; v int;
begin
  while length(made) < 6 loop
    b := uuid_send(gen_random_uuid());
    for i in 0..15 loop
      continue when i in (6, 8);
      v := get_byte(b, i);
      if v < 248 and length(made) < 6 then made := made || substr(alphabet, v % 31 + 1, 1); end if;
    end loop;
  end loop;
  return made;
end;$$;

-- p_try exists so tests can force collisions; production callers leave it empty.
create or replace function public.tt_assign_invite(p_code text, p_try text[] default '{}') returns text
language plpgsql security definer set search_path='' as $$
declare candidate text; attempt int := 0;
begin
  loop
    attempt := attempt + 1;
    candidate := coalesce(p_try[attempt], public.tt_invite_candidate());
    begin
      update public.tt_rooms set invite = candidate where code = p_code and invite is null;
      if not found then select invite into candidate from public.tt_rooms where code = p_code; end if;
      return candidate;
    exception when unique_violation then
      if attempt > 50 then raise exception 'Could not allocate an invitation. Try again'; end if;
    end;
  end loop;
end;$$;

do $$ declare r record; begin
  for r in select code from public.tt_rooms where invite is null loop
    perform public.tt_assign_invite(r.code);
  end loop;
end;$$;

-- Accepts a six-character invitation (any case, spaces/hyphens ignored) or a canonical room code.
create or replace function public.tt_room_code(p_input text) returns text
language plpgsql stable security definer set search_path='' as $$
declare norm text := upper(regexp_replace(coalesce(p_input,''), '[\s-]', '', 'g')); found_code text;
begin
  if length(norm) = 6 then select code into found_code from public.tt_rooms where invite = norm;
  elsif length(norm) between 7 and 40 then select code into found_code from public.tt_rooms where code = norm;
  end if;
  return found_code;
end;$$;

-- Failed join/recovery lookups per user. A code authorizes an attempt, never private state.
create table if not exists public.tt_join_attempts (
  user_id uuid not null, at timestamptz not null default clock_timestamp()
);
create index if not exists tt_join_attempts_user_at on public.tt_join_attempts(user_id, at);
alter table public.tt_join_attempts enable row level security;
revoke all on public.tt_join_attempts from public, anon, authenticated;

create or replace function public.tt_join_blocked() returns boolean
language sql stable security definer set search_path='' as $$
  select count(*) >= 12 from public.tt_join_attempts
   where user_id = auth.uid() and at > clock_timestamp() - interval '10 minutes'
$$;
create or replace function public.tt_join_failed() returns void
language plpgsql security definer set search_path='' as $$
begin
  delete from public.tt_join_attempts where at < clock_timestamp() - interval '1 day';
  insert into public.tt_join_attempts(user_id) values (auth.uid());
end;$$;

-- ---------- Recovery: accepts an invitation alias; the receiving identity must be an account ----------
-- Returns {"error": "..."} (not an exception) for a bad room/code so the failed attempt is recorded.
create or replace function public.tt_recover(p_code text, p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; key_row public.tt_recovery%rowtype; token text := lower(trim(p_token));
  hash text; old_owner uuid; idx int; ps jsonb; s jsonb; c text;
  generic constant text := 'Room or recovery code is invalid';
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  perform public.tt_require_account();
  if public.tt_join_blocked() then raise exception 'Too many attempts. Wait ten minutes and try again'; end if;
  c := public.tt_room_code(p_code);
  if c is null or token is null or token !~ '^[0-9a-f]{64}$' then
    perform public.tt_join_failed(); return jsonb_build_object('error', generic);
  end if;
  hash := encode(sha256(convert_to(token, 'UTF8')), 'hex');
  select * into r from public.tt_rooms where code = c for update;
  select * into key_row from public.tt_recovery where room = r.code and token_hash = hash;
  if not found then perform public.tt_join_failed(); return jsonb_build_object('error', generic); end if;
  s := r.state; ps := s->'players';
  if key_row.seat = -1 then old_owner := r.host;
  else
    select (ord-1)::int, (value->>'uid')::uuid into idx, old_owner
      from jsonb_array_elements(ps) with ordinality a(value, ord)
      where (value->>'id')::int = key_row.seat and not coalesce((value->>'isTestSeat')::boolean, false);
  end if;
  if old_owner is null then perform public.tt_join_failed(); return jsonb_build_object('error', generic); end if;
  -- Identical retry after a successful transfer changes nothing.
  if old_owner = auth.uid() then return public.tt_view(r.code); end if;
  if r.host = auth.uid() or exists(select 1 from jsonb_array_elements(ps) where value->>'uid' = auth.uid()::text) then
    raise exception 'This account already has a different role in this room';
  end if;
  if key_row.seat = -1 then
    update public.tt_rooms set host = auth.uid() where code = r.code;
  else
    ps := jsonb_set(ps, array[idx::text, 'uid'], to_jsonb(auth.uid()::text)); s := jsonb_set(s, '{players}', ps);
    update public.tt_proposals set author = auth.uid() where room = r.code and author = old_owner;
  end if;
  -- Accepted request IDs follow the role, so a restored identity cannot replay an accepted action.
  update public.tt_requests set user_id = auth.uid() where room = r.code and user_id = old_owner
    and not exists(select 1 from public.tt_requests n where n.room = r.code and n.user_id = auth.uid()
                   and n.request_id = public.tt_requests.request_id);
  s := jsonb_set(s, '{hostLog}', jsonb_build_array(clock_timestamp()::text || ' · Access restored for '
    || case when key_row.seat = -1 then 'host' else 'player seat ' || (key_row.seat + 1) end
    || '. The previous identity no longer controls this role.') || (s->'hostLog'));
  update public.tt_rooms set state = s where code = r.code;
  return public.tt_view(r.code);
end;$$;

revoke all on function public.tt_is_account(), public.tt_name_reserved(text), public.tt_require_account(),
  public.tt_profile(), public.tt_profile_save(text,text), public.tt_login_gate(text,text),
  public.tt_invite_candidate(), public.tt_assign_invite(text,text[]), public.tt_room_code(text),
  public.tt_join_blocked(), public.tt_join_failed(), public.tt_recover(text,text)
  from public, anon, authenticated;
grant execute on function public.tt_profile(), public.tt_profile_save(text,text), public.tt_recover(text,text)
  to authenticated;
grant execute on function public.tt_login_gate(text,text) to service_role;
commit;
notify pgrst, 'reload schema';
