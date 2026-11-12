-- ADMIN CHECKS for chat, recovery, notifications and privileges. Run in the SQL Editor AFTER 023.
-- Everything is created inside one transaction and ROLLED BACK. Expected failures are matched
-- against their intended message. Success prints: NOTICE: Release chat/push checks passed (N assertions).
begin;
create function pg_temp.be(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), true) $$;
create function pg_temp.fails(p_sql text, p_like text) returns void language plpgsql as $$
declare msg text;
begin
  begin execute p_sql; exception when others then msg := sqlerrm; end;
  if msg is null then raise exception 'CHECK FAILED — expected an error like "%": %', p_like, p_sql; end if;
  if msg not ilike '%' || p_like || '%' then raise exception 'CHECK FAILED — wrong error "%" (wanted "%"): %', msg, p_like, p_sql; end if;
  perform set_config('tt.checks', (coalesce(nullif(current_setting('tt.checks', true), ''), '0')::int + 1)::text, true);
end;$$;
create function pg_temp.ok(p_cond boolean, p_what text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'CHECK FAILED — %', p_what; end if;
  perform set_config('tt.checks', (coalesce(nullif(current_setting('tt.checks', true), ''), '0')::int + 1)::text, true);
end;$$;
create function pg_temp.pset(p_code text, p_seat int, p_patch jsonb) returns void language sql as $$
  update public.tt_rooms set state = jsonb_set(state, array['players', p_seat::text], (state->'players'->p_seat) || p_patch) where code = p_code $$;
create function pg_temp.account(p_user uuid, p_name text) returns void language plpgsql as $$
begin
  insert into auth.users(id, email, is_anonymous) values (p_user, lower(p_name) || '@check.invalid', false);
  perform pg_temp.be(p_user); perform public.tt_profile_save(lower(p_name) || '_chk', p_name);
end;$$;
-- Chat allows one message per second per seat; tests move earlier messages back instead of sleeping.
create function pg_temp.age_chat() returns void language sql as $$
  update public.tt_chat_messages set sent_at = sent_at - interval '5 seconds' $$;

do $$
declare h uuid := gen_random_uuid(); a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  d uuid := gen_random_uuid(); e uuid := gen_random_uuid(); x uuid := gen_random_uuid(); anon uuid := gen_random_uuid();
  rc text; inv text; other text; s jsonb; v jsonb; res jsonb; req uuid; m1 uuid; dm uuid; r1 uuid; n int; sub_a uuid; sub_x uuid;
  noon timestamptz := (date_trunc('day', clock_timestamp() at time zone 'America/Los_Angeles') + interval '12 hours') at time zone 'America/Los_Angeles';
  ep text := 'https://fcm.googleapis.com/fcm/send/check-device-'; k1 text := repeat('A', 87); k2 text := repeat('b', 22); f record; bad text := '';
begin
  insert into auth.users(id, is_anonymous) values (anon, true);
  perform pg_temp.account(h, 'Hostess'); perform pg_temp.account(a, 'Ada'); perform pg_temp.account(b, 'Bram'); perform pg_temp.account(c, 'Cleo');
  perform pg_temp.account(d, 'Dov'); perform pg_temp.account(e, 'Edda'); perform pg_temp.account(x, 'Xan');
  perform pg_temp.be(h); s := public.tt_create(); rc := s->>'code'; inv := s->>'invite';
  perform pg_temp.be(a); perform public.tt_join(inv); perform pg_temp.be(b); perform public.tt_join(inv); perform pg_temp.be(c); perform public.tt_join(inv);
  perform pg_temp.be(d); perform public.tt_join(inv); perform pg_temp.be(e); perform public.tt_join(inv);

  ------------------------------------------------------------------ H. Chat (lobby onward)
  perform pg_temp.be(a); m1 := (public.tt_chat_send(rc, gen_random_uuid(), 'Hello table')->>'id')::uuid; perform pg_temp.age_chat();
  perform pg_temp.be(h); perform public.tt_command(rc, gen_random_uuid(), 'start');
  update public.tt_rooms set state = state || jsonb_build_object('nextReset', ((clock_timestamp() at time zone 'America/Los_Angeles')::date)::text, 'rules', '{"cutoffHour":24}'::jsonb) where code = rc;
  perform pg_temp.be(b); s := public.tt_view(rc);
  perform pg_temp.ok(s->>'phase' = 'active' and not (s->>'closed')::boolean, 'fixture room opened');
  req := gen_random_uuid(); v := public.tt_chat_send(rc, req, 'Secret pact?', 0); dm := (v->>'id')::uuid;
  res := public.tt_chat_send(rc, req, 'Secret pact?', 0);
  perform pg_temp.ok(res->>'id' = dm::text and (select count(*) from public.tt_chat_messages where room = rc and sender = 1) = 1, 'retry after a lost response returns the same message, no duplicate');
  perform pg_temp.fails(format('select public.tt_chat_send(%L, %L, %L, 0)', rc, req, 'Different words'), 'belongs to a different message');
  perform pg_temp.age_chat();
  perform pg_temp.fails(format('select public.tt_chat_send(%L, gen_random_uuid(), %L, null, %L)', rc, 'Look what Ada said', dm), 'only reply to a message in this conversation');
  perform pg_temp.be(a); r1 := (public.tt_chat_send(rc, gen_random_uuid(), 'Agreed.', 1, dm)->>'id')::uuid; perform pg_temp.age_chat();
  perform pg_temp.fails(format('select public.tt_chat_send(%L, gen_random_uuid(), %L, 1, %L)', rc, 'Quoting the room into a DM', m1), 'only reply to a message in this conversation');
  perform pg_temp.be(b); v := public.tt_chat_list(rc, 0);
  perform pg_temp.ok(jsonb_array_length(v->'messages') = 2 and v->'messages'->1->'reply'->>'excerpt' = 'Secret pact?' and v->'messages'->1->'reply'->>'senderName' = 'Bram', 'quoted reply shown inside the same DM');
  perform pg_temp.be(c);
  perform pg_temp.fails(format('select public.tt_chat_send(%L, gen_random_uuid(), %L, 0, %L)', rc, 'I saw this', dm), 'only reply to a message in this conversation');
  perform pg_temp.fails(format('select public.tt_chat_list(%L, 0, null, %L)', rc, dm), 'Message cursor unavailable');
  perform pg_temp.fails(format('select public.tt_chat_ack(%L, 0, %L)', rc, dm), 'Message cursor unavailable');
  v := public.tt_chat_list(rc, 0); res := public.tt_chat_inbox(rc);
  perform pg_temp.ok(jsonb_array_length(v->'messages') = 0 and res::text not like '%Secret pact%' and res::text not like '%Agreed%', 'a third player cannot read, page into, or preview another pair''s DM');
  perform pg_temp.be(h); v := public.tt_chat_list(rc, 0); res := public.tt_chat_inbox(rc);
  perform pg_temp.ok(jsonb_array_length(v->'messages') = 0 and res::text not like '%Secret pact%' and jsonb_array_length(public.tt_chat_list(rc)->'messages') = 1, 'the host reads room chat but not other pairs'' DMs');
  perform pg_temp.fails(format('select public.tt_chat_send(%L, gen_random_uuid(), %L, 7)', rc, 'x'), 'Choose another real room member');
  perform pg_temp.be(anon); perform pg_temp.fails(format('select public.tt_chat_inbox(%L)', rc), 'Room unavailable');
  perform pg_temp.ok((select count(*) from public.tt_outbox where room = rc and category = 'dm') = 2
    and (select count(*) from public.tt_outbox where room = rc and category = 'dm' and seat not in (0, 1)) = 0, 'DM events are queued for the recipient seat only; room chat queues none');
  -- eliminated players keep room chat and DMs
  perform pg_temp.pset(rc, 4, '{"alive":false,"points":0}'); perform pg_temp.be(e);
  perform public.tt_chat_send(rc, gen_random_uuid(), 'Still here.'); perform pg_temp.age_chat();
  perform public.tt_chat_send(rc, gen_random_uuid(), 'And still whispering.', 2); perform pg_temp.age_chat();
  perform pg_temp.be(c); v := public.tt_chat_list(rc, 4);
  perform pg_temp.ok(v->'messages'->0->>'body' = 'And still whispering.', 'eliminated players keep room chat and DMs');
  perform pg_temp.be(a); perform public.tt_chat_send(rc, gen_random_uuid(), 'One'); 
  perform pg_temp.fails(format('select public.tt_chat_send(%L, gen_random_uuid(), %L)', rc, 'Two'), 'wait a second');
  perform pg_temp.age_chat();

  ------------------------------------------------------------------ J. Notifications (before recovery moves seat 0)
  perform pg_temp.be(a); v := public.tt_push_prefs();
  perform pg_temp.ok(v->'prefs' = '{"dm":true,"income":true,"eliminated":true,"movement":false,"rules":false,"match":false,"bonus":false,"review":false}'::jsonb
    and (v->>'devices')::int = 0, 'defaults: daily income, DMs and your elimination only');
  perform pg_temp.fails($q$select public.tt_push_prefs_save('{"everything":true}')$q$, 'Invalid preferences');
  perform pg_temp.fails(format('select public.tt_push_subscribe(%L, %L, %L)', 'https://evil.example/fcm.googleapis.com/x', k1, k2), 'not supported');
  perform pg_temp.fails(format('select public.tt_push_subscribe(%L, %L, %L)', 'http://fcm.googleapis.com/fcm/send/x', k1, k2), 'not supported');
  perform pg_temp.fails(format('select public.tt_push_subscribe(%L, %L, %L)', 'https://fcm.googleapis.com.evil.example/x', k1, k2), 'not supported');
  perform pg_temp.fails(format('select public.tt_push_subscribe(%L, %L, %L)', 'https://169.254.169.254/latest/meta-data', k1, k2), 'not supported');
  perform pg_temp.fails(format('select public.tt_push_subscribe(%L, %L, %L)', ep || 'a', 'short', k2), 'Invalid push subscription');
  perform public.tt_push_subscribe(ep || 'a', k1, k2); perform public.tt_push_subscribe(ep || 'a', k1, k2);
  select id into sub_a from public.tt_push_subscriptions where user_id = a;
  perform pg_temp.ok((select count(*) from public.tt_push_subscriptions where user_id = a) = 1, 'subscribing the same device twice keeps one row');
  -- quiet hours: nothing leaves between 22:00 and 08:00 Pacific; events stay queued
  v := public.tt_push_claim(200, noon + interval '11 hours');
  perform pg_temp.ok(v = '[]'::jsonb and exists(select 1 from public.tt_outbox where room = rc and seat = 0 and status = 'queued'), 'quiet hours hold every category, including DMs');
  v := public.tt_push_claim(200, noon - interval '4 hours 1 minute');
  perform pg_temp.ok(v = '[]'::jsonb, 'still quiet at 07:59');
  -- after quiet hours: one coalesced, generic summary for Ada (opening income + DM); disabled categories dropped
  v := public.tt_push_claim(200, noon + interval '20 hours');
  perform pg_temp.ok(jsonb_array_length(v) = 1 and v->0->'subscription'->>'id' = sub_a::text and v->0->'payload'->>'body' = 'You have 2 new updates.'
    and v->0->'payload'->>'title' = 'Turn Tactics' and v::text not like '%Secret%' and v::text not like '%Bram%' and (v->0->'payload')::text not like '%point%'
    and v->0->'payload'->>'url' like './online.html?room=%', 'one summary after quiet hours; generic text with no sender, message or resource detail');
  perform pg_temp.ok((select count(*) from public.tt_outbox where room = rc and category = 'match' and status = 'dropped') > 0
    and not exists(select 1 from public.tt_outbox where room = rc and seat <> 0 and status = 'sending'), 'switched-off categories and seats without a device are dropped, not delivered');
  res := public.tt_push_claim(200, noon + interval '20 hours 1 minute');
  perform pg_temp.ok(res = '[]'::jsonb, 'a leased event is not handed out twice');
  -- transient failure → retried once the lease is reported; success → never again
  perform public.tt_push_report(jsonb_build_array(jsonb_build_object('subscription', sub_a, 'ids', v->0->'ids', 'status', 'retry')));
  v := public.tt_push_claim(200, noon + interval '20 hours 2 minutes');
  perform pg_temp.ok(jsonb_array_length(v) = 1 and (select max(attempts) from public.tt_outbox where room = rc and seat = 0) = 2, 'failed delivery is retried');
  perform public.tt_push_report(jsonb_build_array(jsonb_build_object('subscription', sub_a, 'ids', v->0->'ids', 'status', 'ok')));
  res := public.tt_push_claim(200, noon + interval '20 hours 3 minutes');
  perform pg_temp.ok(res = '[]'::jsonb and not exists(select 1 from public.tt_outbox where room = rc and seat = 0 and status not in ('sent','dropped')), 'a delivered event is never sent again');
  -- an opted-in category is delivered; single DM routes to chat
  perform public.tt_push_prefs_save('{"movement":true,"income":false}');
  perform pg_temp.pset(rc, 1, '{"x":0,"y":0}'); perform pg_temp.pset(rc, 0, '{"x":4,"y":4}'); perform pg_temp.pset(rc, 2, '{"x":6,"y":6}'); perform pg_temp.pset(rc, 3, '{"x":7,"y":0}');
  perform pg_temp.be(b); perform public.tt_command(rc, gen_random_uuid(), 'move', null, 'right');
  v := public.tt_push_claim(200, noon);
  perform pg_temp.ok(jsonb_array_length(v) = 1 and v->0->'payload'->>'body' = 'You have a new update.' and v->0->'payload'->>'url' like '%view=field', 'opted-in movement alert delivered, still generic');
  perform public.tt_push_report(jsonb_build_array(jsonb_build_object('subscription', sub_a, 'ids', v->0->'ids', 'status', 'ok')));
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.tt_push_claim(int,timestamptz)', 'EXECUTE') and not has_function_privilege('authenticated', 'public.tt_push_report(jsonb)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.tt_notify(text,int,text,text)', 'EXECUTE') and not has_table_privilege('authenticated', 'public.tt_push_subscriptions', 'SELECT')
    and not has_table_privilege('authenticated', 'public.tt_outbox', 'INSERT'), 'clients cannot claim, report, forge events or read subscriptions');

  ------------------------------------------------------------------ I. Recovery into an account; old identity denied everywhere
  perform pg_temp.be(a); perform public.tt_save_recovery(rc, repeat('a', 64));
  perform pg_temp.be(anon); perform pg_temp.fails(format('select public.tt_recover(%L, %L)', inv, repeat('a', 64)), 'Create an account or sign in');
  perform pg_temp.be(c); perform pg_temp.fails(format('select public.tt_recover(%L, %L)', inv, repeat('a', 64)), 'already has a different role');
  perform pg_temp.be(x); v := public.tt_recover(inv, repeat('f', 64));
  perform pg_temp.ok(v->>'error' = 'Room or recovery code is invalid' and (select count(*) from public.tt_join_attempts where user_id = x) = 1, 'wrong recovery code: generic error, attempt counted');
  v := public.tt_recover('NOSUCH', repeat('a', 64));
  perform pg_temp.ok(v->>'error' = 'Room or recovery code is invalid', 'unknown room gives the same generic error');
  s := public.tt_recover(lower(inv), repeat('a', 64)); s := public.tt_recover(lower(inv), repeat('a', 64));
  perform pg_temp.ok((s->>'me')::int = 0 and s->'players'->0->>'name' = 'Ada' and (s->'players'->0->>'points')::int = 1, 'role restored by invitation alias with its name and resources');
  v := public.tt_chat_list(rc, 1);
  perform pg_temp.ok(jsonb_array_length(v->'messages') = 2, 'DM history and read state follow the seat');
  perform pg_temp.be(a);
  perform pg_temp.fails(format('select public.tt_view(%L)', rc), 'Room unavailable');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L)', rc, 'shield'), 'Room unavailable');
  perform pg_temp.fails(format('select public.tt_chat_list(%L, 1)', rc), 'Room unavailable');
  perform pg_temp.fails(format('select public.tt_chat_send(%L, gen_random_uuid(), %L)', rc, 'ghost'), 'Room unavailable');
  -- a DM for seat 0 now belongs to Xan; Ada's still-subscribed device must receive nothing
  perform pg_temp.be(b); perform public.tt_chat_send(rc, gen_random_uuid(), 'For the new owner', 0); perform pg_temp.age_chat();
  v := public.tt_push_claim(200, noon);
  perform pg_temp.ok(v = '[]'::jsonb and (select status from public.tt_outbox where room = rc and seat = 0 order by id desc limit 1) = 'dropped', 'the previous identity''s device gets no new private updates');
  -- the same physical device signs in as Xan: the subscription moves, it is never shared
  perform pg_temp.be(x); perform public.tt_push_subscribe(ep || 'a', k1, k2); select id into sub_x from public.tt_push_subscriptions where user_id = x;
  perform pg_temp.ok(sub_x = sub_a and not exists(select 1 from public.tt_push_subscriptions where user_id = a), 'a device belongs to one account at a time');
  perform pg_temp.be(b); perform public.tt_chat_send(rc, gen_random_uuid(), 'Welcome back', 0); perform pg_temp.age_chat();
  v := public.tt_push_claim(200, noon);
  perform pg_temp.ok(jsonb_array_length(v) = 1 and v->0->'payload'->>'url' like '%view=chat' and v::text not like '%Welcome%', 'current owner is notified; single DM opens chat without a preview');
  perform public.tt_push_report(jsonb_build_array(jsonb_build_object('subscription', sub_x, 'ids', v->0->'ids', 'status', 'gone')));
  perform pg_temp.ok(not exists(select 1 from public.tt_push_subscriptions where id = sub_x), 'expired subscription removed');
  perform pg_temp.be(x); perform public.tt_push_subscribe(ep || 'b', k1, k2); v := public.tt_push_unsubscribe(ep || 'b');
  perform pg_temp.ok((v->>'devices')::int = 0, 'sign-out removes this device');

  ------------------------------------------------------------------ Retention and deletion
  perform pg_temp.be(h); other := public.tt_create()->>'code';
  perform pg_temp.be(b); perform public.tt_join(other); perform public.tt_chat_send(other, gen_random_uuid(), 'Old but active');
  update public.tt_chat_messages set sent_at = sent_at - interval '30 days' where room = other;
  perform pg_temp.be(h);
  perform pg_temp.fails(format('select public.tt_delete_room(%L, %L)', rc, 'DELETE'), 'Only a finished game can be deleted');
  update public.tt_rooms set state = state || jsonb_build_object('phase', 'ended', 'closed', true, 'winners', '[0]'::jsonb, 'endedAt', clock_timestamp() - interval '23 hours') where code = rc;
  perform pg_temp.be(e); perform public.tt_chat_send(rc, gen_random_uuid(), 'Good game.');
  n := public.tt_chat_purge();
  perform pg_temp.ok(n = 0 and jsonb_array_length(public.tt_chat_list(rc)->'messages') >= 3, 'finished-game chat stays for 24 hours');
  update public.tt_rooms set state = jsonb_set(state, '{endedAt}', to_jsonb(clock_timestamp() - interval '24 hours 1 minute')) where code = rc;
  perform pg_temp.fails(format('select public.tt_chat_list(%L)', rc), 'expired');
  perform pg_temp.fails(format('select public.tt_chat_inbox(%L)', rc), 'expired');
  perform pg_temp.fails(format('select public.tt_chat_send(%L, gen_random_uuid(), %L)', rc, 'late'), 'expired');
  n := public.tt_chat_purge();
  perform pg_temp.ok(n > 0 and not exists(select 1 from public.tt_chat_messages where room = rc) and (select count(*) from public.tt_chat_messages where room = other) = 1
    and exists(select 1 from public.tt_rooms where code = rc), 'expiry deletes messages (and with them every quote); active-game chat and the result are kept');
  perform pg_temp.be(b); perform pg_temp.fails(format('select public.tt_delete_room(%L, %L)', rc, 'DELETE'), 'Host only');
  perform pg_temp.be(h); perform pg_temp.fails(format('select public.tt_delete_room(%L, %L)', rc, 'yes'), 'Type DELETE');
  v := public.tt_delete_room(rc, 'DELETE'); res := public.tt_delete_room(rc, 'DELETE');
  perform pg_temp.ok((v->>'deleted')::boolean and (res->>'deleted')::boolean and not exists(select 1 from public.tt_rooms where code = rc)
    and not exists(select 1 from public.tt_outbox where room = rc) and exists(select 1 from public.tt_profiles where user_id = b), 'host deletion removes the finished room, not accounts; repeat is harmless');

  ------------------------------------------------------------------ K. Privilege audit over every Turn Tactics object
  for f in select p.oid::regprocedure::text as sig, p.oid, p.prosecdef, p.proconfig from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'public' and p.proname like 'tt\_%' loop
    if not exists(select 1 from unnest(coalesce(f.proconfig, '{}')) cfg where cfg like 'search_path=%') then bad := bad || ' no-search_path:' || f.sig; end if;
    if has_function_privilege('anon', f.oid, 'EXECUTE') or has_function_privilege('public', f.oid, 'EXECUTE') then bad := bad || ' anon-exec:' || f.sig; end if;
  end loop;
  for f in select cl.oid, cl.relname, cl.relrowsecurity from pg_class cl join pg_namespace ns on ns.oid = cl.relnamespace
            where ns.nspname = 'public' and cl.relkind = 'r' and cl.relname like 'tt\_%' loop
    if not f.relrowsecurity then bad := bad || ' no-rls:' || f.relname; end if;
    if has_table_privilege('anon', f.oid, 'SELECT,INSERT,UPDATE,DELETE') or has_table_privilege('authenticated', f.oid, 'SELECT,INSERT,UPDATE,DELETE') then bad := bad || ' table-grant:' || f.relname; end if;
  end loop;
  perform pg_temp.ok(bad = '', 'privilege audit:' || bad);
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.tt_clock_apply(text,timestamptz)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.tt_amend_apply(text,text,text,jsonb,uuid,uuid)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.tt_commit(text,jsonb,jsonb)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.tt_chat_purge()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.tt_assign_invite(text,text[])', 'EXECUTE'), 'internal helpers are not client-callable');

  raise notice 'Release chat/push checks passed (% assertions). Fixtures roll back.', current_setting('tt.checks');
end;$$;
rollback;
