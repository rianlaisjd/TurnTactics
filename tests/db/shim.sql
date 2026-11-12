-- LOCAL TEST SHIM ONLY. Never run against Supabase: it imitates the parts of the
-- Supabase auth schema and roles that the Turn Tactics SQL touches.
do $$ begin  -- roles are cluster-wide: tolerate a re-run
  if not exists(select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists(select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema auth;
create table auth.users(id uuid primary key, email text unique, is_anonymous boolean not null default false, created_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
    nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub'),'')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
-- Supabase's default privileges grant EXECUTE on new public functions to these roles;
-- reproduce that so the migrations' explicit REVOKEs are actually exercised.
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
