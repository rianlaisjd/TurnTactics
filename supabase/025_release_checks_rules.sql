-- ADMIN CHECKS for release migrations 020–023. Run in the SQL Editor AFTER 023.
-- Every fixture (users, rooms, messages) is created inside one transaction and ROLLED BACK.
-- Each expected failure is matched against its intended message, not just "any error".
-- Success prints: NOTICE: Release checks passed (N assertions). Fixtures roll back.
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
create function pg_temp.pget(p_code text, p_seat int, p_key text) returns text language sql as $$
  select state->'players'->p_seat->>p_key from public.tt_rooms where code = p_code $$;
create function pg_temp.sget(p_code text, p_key text) returns text language sql as $$
  select state->>p_key from public.tt_rooms where code = p_code $$;
create function pg_temp.account(p_user uuid, p_name text) returns void language plpgsql as $$
begin
  insert into auth.users(id, email, is_anonymous) values (p_user, lower(p_name) || '@check.invalid', false);
  perform pg_temp.be(p_user); perform public.tt_profile_save(lower(p_name) || '_chk', p_name);
end;$$;

do $$
declare h uuid := gen_random_uuid(); a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  d uuid := gen_random_uuid(); e uuid := gen_random_uuid(); x uuid := gen_random_uuid(); anon uuid := gen_random_uuid(); bare uuid := gen_random_uuid();
  rc text; inv text; room2 text; legacy text; slide text; nrm text; s jsonb; v jsonb; res jsonb; i int; n int; req uuid; pid uuid; aid uuid;
  m1 uuid; m2 uuid; dm uuid; t timestamptz; total int; day0 date; noon timestamptz; ep text := 'https://fcm.googleapis.com/fcm/send/check-device-';
begin
  ------------------------------------------------------------------ A. Board mapping and versions
  for i in 5..20 loop
    perform pg_temp.ok(public.tt_board_size('owner-2026-11', i) = case when i <= 6 then 8 when i = 7 then 9 when i <= 9 then 10 when i = 10 then 11
      when i <= 12 then 12 when i <= 14 then 13 when i <= 16 then 14 else 15 end, 'board size for ' || i || ' players');
  end loop;
  perform pg_temp.ok(public.tt_board_size('owner-2026-11', 4) is null and public.tt_board_size('owner-2026-11', 21) is null, 'no board outside 5–20');
  perform pg_temp.ok(public.tt_board_size('slideshow-2026-11', 6) is null, 'slideshow version keeps its six-player gap');
  perform pg_temp.fails($q$select public.tt_rules_profile('future-9999')$q$, 'Unsupported rules version');
  perform pg_temp.ok((public.tt_rules('{}'::jsonb)->>'baseRange')::int = 2 and (public.tt_rules('{}'::jsonb)->>'cutoffHour')::int = 19
    and (public.tt_rules('{}'::jsonb)->>'costProposal')::int = 4, 'legacy profile preserved');
  perform pg_temp.ok((public.tt_rules('{"rulesVersion":"slideshow-2026-11"}')->>'baseRange')::int = 3, 'slideshow range 3 preserved');
  perform pg_temp.ok((public.tt_rules('{"rulesVersion":"owner-2026-11"}')->>'baseRange')::int = 4, 'new version range 4');
  perform pg_temp.ok(public.tt_square('{"rulesVersion":"owner-2026-11","size":8}', 0, 7) = 'a1'
    and public.tt_square('{"rulesVersion":"owner-2026-11","size":8}', 7, 0) = 'h8'
    and public.tt_square('{"rulesVersion":"owner-2026-11","size":15}', 14, 14) = 'o1', 'chess coordinates: a1 lower-left');

  ------------------------------------------------------------------ B. Accounts
  insert into auth.users(id, is_anonymous) values (anon, true);
  insert into auth.users(id, email, is_anonymous) values (bare, 'bare@check.invalid', false);
  perform pg_temp.be(anon);
  perform pg_temp.fails('select public.tt_create()', 'Create an account or sign in');
  perform pg_temp.fails($q$select public.tt_profile_save('anon_user','Anon')$q$, 'Create an account or sign in first');
  perform pg_temp.be(bare);
  perform pg_temp.fails('select public.tt_create()', 'Choose a username and display name first');
  perform pg_temp.fails($q$select public.tt_profile_save('x','Bare')$q$, '3–20 letters');
  perform pg_temp.fails($q$select public.tt_profile_save('bare_ok','Host / Referee')$q$, 'reserved');
  perform pg_temp.account(h, 'Hostess'); perform pg_temp.account(a, 'Ada'); perform pg_temp.account(b, 'Bram');
  perform pg_temp.account(c, 'Cleo'); perform pg_temp.account(d, 'Dov'); perform pg_temp.account(e, 'Edda'); perform pg_temp.account(x, 'Xan');
  perform pg_temp.be(bare);
  perform pg_temp.fails($q$select public.tt_profile_save('ADA_chk','Bare')$q$, 'username is taken');
  perform pg_temp.ok((public.tt_login_gate('ada_chk', '203.0.113.9')->>'email') = 'ada@check.invalid', 'username resolves for the service role');
  perform pg_temp.ok(public.tt_login_gate('nobody_here', '203.0.113.9')->'email' = 'null'::jsonb, 'unknown username resolves to nothing');
  for i in 1..9 loop perform public.tt_login_gate('ada_chk', '203.0.113.9'); end loop;
  perform pg_temp.ok(not (public.tt_login_gate('ada_chk', '203.0.113.9')->>'allowed')::boolean, 'username sign-in is rate limited');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.tt_login_gate(text,text)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.tt_login_gate(text,text)', 'EXECUTE')
    and has_function_privilege('service_role', 'public.tt_login_gate(text,text)', 'EXECUTE'), 'login gate is service-only');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.tt_profiles', 'SELECT'), 'no direct profile reads (no username/email directory)');

  ------------------------------------------------------------------ C. Invitations
  perform pg_temp.be(h); s := public.tt_create(); rc := s->>'code'; inv := s->>'invite';
  perform pg_temp.ok(inv ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' and length(rc) = 12, 'six-character invitation plus canonical code');
  perform pg_temp.ok(s->>'rulesVersion' = 'owner-2026-11' and (s->'config'->>'baseRange')::int = 4 and (s->>'cutoffHour')::int = 18, 'new rooms use the new rules version');
  perform pg_temp.be(a); s := public.tt_join(lower(substr(inv, 1, 3)) || '- ' || lower(substr(inv, 4)));
  perform pg_temp.ok(s->>'code' = rc and s->'players'->0->>'name' = 'Ada', 'join by normalised invitation, default display name');
  perform pg_temp.ok((s->'players'->0->>'range')::int = 4 and (s->'players'->0->>'points')::int = 0 and (s->'players'->0->>'hearts')::int = 3, 'range 4, 3 hearts, no opening point in the lobby');
  perform pg_temp.be(b); s := public.tt_join(rc, 'The Baron');
  perform pg_temp.ok(s->'players'->1->>'name' = 'The Baron', 'legacy 12-character code and room-specific name');
  perform pg_temp.be(c);
  perform pg_temp.fails(format('select public.tt_join(%L, %L)', inv, 'ada'), 'already used in this room');
  perform pg_temp.fails(format('select public.tt_join(%L, %L)', inv, 'Referee'), 'reserved');
  v := public.tt_join('ZZZZZZ');
  perform pg_temp.ok(v ? 'error' and (select count(*) from public.tt_join_attempts where user_id = c) = 1, 'unknown invitation: generic error, attempt recorded');
  perform pg_temp.fails(format('select public.tt_view(%L)', rc), 'Room unavailable');
  for i in 1..11 loop perform public.tt_join('ZZZZZ' || i); end loop;
  perform pg_temp.fails(format('select public.tt_join(%L)', inv), 'Too many attempts');
  delete from public.tt_join_attempts where user_id = c;
  s := public.tt_join(inv); perform pg_temp.ok((s->>'me')::int = 2, 'third player seated');
  perform pg_temp.be(h); room2 := public.tt_create()->>'code';
  update public.tt_rooms set invite = null where code = room2;
  legacy := public.tt_assign_invite(room2, array[inv, inv]);
  perform pg_temp.ok(legacy <> inv and (select invite from public.tt_rooms where code = room2) = legacy and legacy ~ '^[A-Z2-9]{6}$', 'invitation collision retried');
  perform pg_temp.be(anon); perform pg_temp.fails(format('select public.tt_join(%L)', inv), 'Create an account or sign in');

  ------------------------------------------------------------------ D. Preserved versions (legacy + slideshow rooms are not rewritten)
  legacy := 'LEGACYCHECK1'; slide := 'SLIDECHECK01';
  insert into public.tt_rooms(code, host, state) values (legacy, h, jsonb_build_object('phase','active','day',3,'size',5,'closed',false,'winner',null,'isTest',true,
    'votes','{}'::jsonb,'events','[]'::jsonb,'hostLog','[]'::jsonb,'players', jsonb_build_array(
      jsonb_build_object('id',0,'uid',anon,'name','Old One','x',0,'y',0,'hearts',3,'points',6,'range',2,'shield',true,'alive',true),
      jsonb_build_object('id',1,'uid',b,'name','Old Two','x',0,'y',2,'hearts',1,'points',2,'range',2,'shield',false,'alive',true),
      jsonb_build_object('id',2,'uid',c,'name','Old Three','x',4,'y',4,'hearts',3,'points',2,'range',2,'shield',false,'alive',true))));
  insert into public.tt_rooms(code, host, state) values (slide, h, jsonb_build_object('rulesVersion','slideshow-2026-11','phase','lobby','day',1,'size',8,'closed',false,
    'winner',null,'votes','{}'::jsonb,'events','[]'::jsonb,'hostLog','[]'::jsonb,'players','[]'::jsonb));
  perform pg_temp.be(anon); s := public.tt_view(legacy);
  perform pg_temp.ok(s->>'rulesVersion' = 'legacy-v0.5' and (s->>'cutoffHour')::int = 19 and (s->>'proposalCost')::int = 4
    and (s->'players'->0->>'range')::int = 2, 'legacy room: anonymous seat still works, range untouched by the new frontend/migration');
  s := public.tt_command(legacy, gen_random_uuid(), 'attack', 1);
  perform pg_temp.ok(pg_temp.pget(legacy, 1, 'alive') = 'false' and pg_temp.pget(legacy, 1, 'points') = '2', 'legacy elimination keeps its recorded balance');
  perform pg_temp.ok(s->'events'->>0 like 'Old One eliminated Old Two.%', 'final attacker announced publicly');
  s := public.tt_command(legacy, gen_random_uuid(), 'move', null, 'right');
  perform pg_temp.ok(s->'events'->>0 = 'Old One moved to (2, 1).', 'legacy rooms keep numeric coordinates');
  perform pg_temp.be(a); s := public.tt_join(slide);
  perform pg_temp.ok((s->'players'->0->>'range')::int = 3 and s->>'rulesVersion' = 'slideshow-2026-11', 'slideshow lobby keeps range 3');
  perform pg_temp.be(h);
  perform pg_temp.fails(format('select public.tt_migrate_rules(%L, gen_random_uuid(), %L, %L)', slide, 'owner-2026-11', 'yes'), 'Type MIGRATE');
  s := public.tt_migrate_rules(slide, gen_random_uuid(), 'owner-2026-11', 'MIGRATE');
  perform pg_temp.ok((s->'players'->0->>'range')::int = 4, 'consented lobby migration applies new starting range');
  s := public.tt_migrate_rules(legacy, gen_random_uuid(), 'owner-2026-11', 'MIGRATE');
  perform pg_temp.ok(pg_temp.pget(legacy, 0, 'range') = '2' and pg_temp.pget(legacy, 2, 'range') = '2', 'running-game migration never raises anyone''s range');

  ------------------------------------------------------------------ E. Core actions (test room: manual clock, three real players + two placeholders)
  perform pg_temp.be(h); s := public.tt_fill_test_seats(rc);
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, p_size => 5)', rc, 'start'), 'require a 8 by 8 board');
  s := public.tt_command(rc, gen_random_uuid(), 'start');
  perform pg_temp.ok((s->>'size')::int = 8 and s->>'phase' = 'active' and (select count(distinct (value->>'x') || ',' || (value->>'y')) from jsonb_array_elements(s->'players')) = 5
    and not exists(select 1 from jsonb_array_elements(s->'players') where (value->>'points')::int <> 1 or (value->>'range')::int <> 4), 'five players: 8 × 8, unique squares, one opening point, range 4');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, 0)', rc, 'attack'), 'host referees');
  -- deterministic layout: Ada a8, Baron a7 (adjacent), Cleo c6 (L-shaped from Ada: distance 4), seats 3/4 far away
  perform pg_temp.pset(rc, 0, '{"x":0,"y":0,"points":10}'); perform pg_temp.pset(rc, 1, '{"x":0,"y":1,"points":3}');
  perform pg_temp.pset(rc, 2, '{"x":2,"y":2,"points":3}'); perform pg_temp.pset(rc, 3, '{"x":7,"y":7}'); perform pg_temp.pset(rc, 4, '{"x":5,"y":0}');
  perform pg_temp.be(a);
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, null, %L)', rc, 'move', 'down'), 'Tile blocked');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, null, %L)', rc, 'move', 'up'), 'Tile blocked');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, null, %L)', rc, 'move', 'upleft'), 'Choose a direction');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '10', 'rejected requests never charge');
  req := gen_random_uuid(); s := public.tt_command(rc, req, 'move', null, 'right'); s := public.tt_command(rc, req, 'move', null, 'right');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'x') = '1' and pg_temp.pget(rc, 0, 'points') = '9' and s->'events'->>0 = 'Ada moved to b8.', 'move: one square, one point, public chess coordinate, duplicate request ignored');
  s := public.tt_command(rc, gen_random_uuid(), 'move', null, 'left');
  s := public.tt_command(rc, gen_random_uuid(), 'attack', 2);
  perform pg_temp.ok(pg_temp.pget(rc, 2, 'hearts') = '2' and pg_temp.pget(rc, 0, 'points') = '7' and s->'events'->>0 not like '%Cleo%', 'L-shaped target at Manhattan 4 is in range; private attack not published');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, 4)', rc, 'attack'), 'Target out of range');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, -1)', rc, 'give'), 'Choose another living player');
  select sum((value->>'points')::int) into total from jsonb_array_elements((select state->'players' from public.tt_rooms where code = rc));
  s := public.tt_command(rc, gen_random_uuid(), 'give', 1);
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '6' and pg_temp.pget(rc, 1, 'points') = '4'
    and total = (select sum((value->>'points')::int) from jsonb_array_elements((select state->'players' from public.tt_rooms where code = rc))), 'transfer moves exactly one point and creates none');
  s := public.tt_command(rc, gen_random_uuid(), 'range');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'range') = '5' and pg_temp.pget(rc, 0, 'points') = '4', 'range upgrade: two points, +1');
  perform pg_temp.be(b); s := public.tt_command(rc, gen_random_uuid(), 'shield');
  perform pg_temp.ok(pg_temp.pget(rc, 1, 'shield') = 'true' and pg_temp.pget(rc, 1, 'points') = '2' and pg_temp.pget(rc, 1, 'hearts') = '3', 'shield: two points, no extra heart');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L)', rc, 'shield'), 'Already shielded');
  perform pg_temp.be(c); s := public.tt_view(rc);
  perform pg_temp.ok(not (s->'players'->1 ? 'shield') and not (s->'players'->1 ? 'points') and not (s->'players'->1 ? 'hearts') and s->'hostLog' = '[]'::jsonb
    and s::text not like '%' || a::text || '%', 'other players'' resources, shield, host log and account ids stay private');
  perform pg_temp.be(a);
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, 1)', rc, 'attack'), 'Target shielded; no points spent');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '4', 'shielded attack is free');
  perform pg_temp.pset(rc, 0, '{"points":0}');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, 2)', rc, 'attack'), 'Not enough points');
  perform pg_temp.pset(rc, 0, '{"points":5}'); perform pg_temp.pset(rc, 2, '{"hearts":1,"points":7}');
  s := public.tt_command(rc, gen_random_uuid(), 'attack', 2);
  perform pg_temp.ok(pg_temp.pget(rc, 2, 'alive') = 'false' and pg_temp.pget(rc, 2, 'points') = '0' and pg_temp.pget(rc, 2, 'hearts') = '0'
    and s->'events'->>0 = 'Ada eliminated Cleo.', 'elimination: zero hearts, points forfeited, announced');
  perform pg_temp.be(c);
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L)', rc, 'shield'), 'You have been eliminated');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, 2)', rc, 'vote'), 'Choose a living recipient');
  s := public.tt_command(rc, gen_random_uuid(), 'vote', 0);
  perform pg_temp.be(a); perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, 1)', rc, 'vote'), 'Only eliminated players may vote');
  perform pg_temp.be(b); s := public.tt_view(rc);
  perform pg_temp.ok(not (s ? 'votes') and s::text not like '%ballot%', 'ballots are private');
  perform pg_temp.be(h);
  req := gen_random_uuid(); s := public.tt_command(rc, req, 'next_day'); s := public.tt_command(rc, req, 'next_day');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '6' and pg_temp.pget(rc, 1, 'points') = '3' and pg_temp.pget(rc, 2, 'points') = '0'
    and pg_temp.pget(rc, 1, 'shield') = 'false' and (s->>'day')::int = 2, 'reset once: income for the living, strict-majority bonus, shield expiry, none for the eliminated');
  s := public.tt_command(rc, gen_random_uuid(), 'next_day');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '7', 'a settled ballot is not counted again');
  -- tie: two eliminated voters disagree → no bonus
  perform pg_temp.pset(rc, 3, jsonb_build_object('alive', false, 'uid', d, 'isTestSeat', false));
  perform pg_temp.be(c); perform public.tt_command(rc, gen_random_uuid(), 'vote', 0);
  perform pg_temp.be(d); perform public.tt_command(rc, gen_random_uuid(), 'vote', 1);
  perform pg_temp.be(h); perform public.tt_command(rc, gen_random_uuid(), 'next_day');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '8' and pg_temp.pget(rc, 1, 'points') = '5', 'tied ballots award nothing');

  ------------------------------------------------------------------ F. Rules desk
  perform pg_temp.be(a); perform pg_temp.fails(format('select public.tt_amend_preview(%L, %L::jsonb)', rc, '[]'), 'Host only');
  perform pg_temp.fails(format('select public.tt_amend(%L, gen_random_uuid(), %L, %L, %L::jsonb)', rc, 't', 'r', '[{"type":"set","key":"costMove","value":0}]'), 'Host only');
  perform pg_temp.be(h); select state into s from public.tt_rooms where code = rc;
  res := public.tt_amend_preview(rc, '[{"type":"set","key":"costMove","value":2},{"type":"set","key":"costMove","value":3},{"type":"set","key":"sql","value":1},
    {"type":"set","key":"dailyIncome","value":99},{"type":"run","code":"drop table"},{"type":"set","key":"allowAttack","value":"no"},{"type":"adjust","resource":"hearts","target":"living","amount":-9}]');
  perform pg_temp.ok(not (res->>'ok')::boolean and jsonb_array_length(res->'errors') = 6 and res->'errors'->>0 like '%more than once%' and res->'errors'->>1 = 'Unsupported setting'
    and res->'errors'->>2 like '%between 0 and 20%' and res->'errors'->>3 = 'Unsupported effect type' and res->'errors'->>5 like '%eliminate every living player%', 'preview reports each invalid or conflicting effect');
  perform pg_temp.ok(s = (select state from public.tt_rooms where code = rc), 'preview changes nothing');
  perform pg_temp.fails(format('select public.tt_amend(%L, gen_random_uuid(), %L, %L, %L::jsonb)', rc, 'Mixed', 'One bad effect',
    '[{"type":"set","key":"costMove","value":2},{"type":"adjust","resource":"points","target":"living","amount":3},{"type":"set","key":"dailyIncome","value":99}]'), 'between 0 and 20');
  perform pg_temp.ok(s = (select state from public.tt_rooms where code = rc) and not exists(select 1 from public.tt_amendments where room = rc), 'a multi-effect amendment is all-or-nothing');
  perform pg_temp.fails(format('select public.tt_amend(%L, gen_random_uuid(), %L, %L, %L::jsonb)', rc, 'No reason', '', '[{"type":"set","key":"costMove","value":2}]'), 'public reason');
  res := public.tt_amend_preview(rc, '[{"type":"set","key":"baseRange","value":5},{"type":"set","key":"dailyIncome","value":2},{"type":"set","key":"costMove","value":2},
    {"type":"adjust","resource":"points","target":1,"amount":2},{"type":"written","text":"No attacking on Sundays."},{"type":"set","key":"moveLimit","value":1,"when":"next_reset"}]');
  perform pg_temp.ok((res->>'ok')::boolean and jsonb_array_length(res->'lines') = 6 and (res->'lines'->4->>'hostEnforced')::boolean and res->'lines'->5->>'when' = 'next_reset'
    and (res->>'changesExisting')::boolean and not (res->>'endsMatchNow')::boolean and res::text not like '%"points"%', 'preview: what changes, timing, host-enforced label, no private totals');
  req := gen_random_uuid();
  s := public.tt_amend(rc, req, 'Longer reach, richer days', 'Agreed at the table.', '[{"type":"set","key":"baseRange","value":5},{"type":"set","key":"dailyIncome","value":2},
    {"type":"set","key":"costMove","value":2},{"type":"adjust","resource":"points","target":1,"amount":2},{"type":"written","text":"No attacking on Sundays."},{"type":"set","key":"moveLimit","value":1,"when":"next_reset"}]');
  s := public.tt_amend(rc, req, 'Longer reach, richer days', 'Agreed at the table.', '[{"type":"set","key":"baseRange","value":5}]');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'range') = '6' and pg_temp.pget(rc, 1, 'range') = '5', 'base range shift keeps the purchased upgrade');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '8' and pg_temp.pget(rc, 1, 'points') = '7', 'income setting grants nothing now; named grant applied once despite retry');
  perform pg_temp.ok((select count(*) from public.tt_amendments where room = rc) = 1 and s->'amendments'->0->>'origin' = 'host' and s->'amendments'->0->>'proposerName' is null
    and s->'amendments'->0->>'status' = 'scheduled' and s->'events'->>0 like 'Rule amendment by the host: Longer reach, richer days — %Reason: Agreed at the table.'
    and s->'events'->>0 not like '%7%', 'host amendment: attributed to the host, public reason, no resource totals in Dispatch');
  perform pg_temp.be(a); perform pg_temp.pset(rc, 0, '{"points":1}');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, null, %L)', rc, 'move', 'right'), 'Not enough points');
  perform pg_temp.pset(rc, 0, '{"points":8}');
  s := public.tt_command(rc, gen_random_uuid(), 'move', null, 'right'); s := public.tt_command(rc, gen_random_uuid(), 'move', null, 'left');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '4', 'amended move cost (2) charged; limit not yet in force');
  perform pg_temp.be(h); s := public.tt_command(rc, gen_random_uuid(), 'next_day');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '6' and (s->'config'->>'moveLimit')::int = 1 and s->'amendments'->0->>'status' = 'applied'
    and (select jsonb_array_length(state->'pending') from public.tt_rooms where code = rc) = 0, 'reset: new income (2) and the scheduled effect applied');
  s := public.tt_command(rc, gen_random_uuid(), 'next_day');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'points') = '8' and (select count(*) from jsonb_array_elements_text(s->'events') where value like 'Scheduled rule amendment took effect%') = 1, 'scheduled effect processed exactly once');
  perform pg_temp.be(a); s := public.tt_command(rc, gen_random_uuid(), 'move', null, 'right');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, null, %L)', rc, 'move', 'left'), 'Daily movement limit reached');
  -- shield duration: an active one-day shield keeps its expiry; a new one lasts two resets
  perform pg_temp.be(b); perform public.tt_command(rc, gen_random_uuid(), 'shield');
  perform pg_temp.be(h); perform public.tt_amend(rc, gen_random_uuid(), 'Sturdier shields', 'House vote.', '[{"type":"set","key":"shieldDays","value":2},{"type":"set","key":"allowAttack","value":false}]');
  perform pg_temp.be(a); perform public.tt_command(rc, gen_random_uuid(), 'shield');
  perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L, 1)', rc, 'attack'), 'disabled by a rule amendment');
  perform pg_temp.be(h); perform public.tt_command(rc, gen_random_uuid(), 'next_day');
  perform pg_temp.ok(pg_temp.pget(rc, 1, 'shield') = 'false' and pg_temp.pget(rc, 0, 'shield') = 'true', 'existing shield keeps old expiry; new shield lasts longer');
  perform public.tt_command(rc, gen_random_uuid(), 'next_day');
  perform pg_temp.ok(pg_temp.pget(rc, 0, 'shield') = 'false', 'two-reset shield ends after the second reset');
  -- scheduled amendment can be cancelled before it takes effect
  s := public.tt_amend(rc, gen_random_uuid(), 'Tax day', 'Trial.', '[{"type":"adjust","resource":"points","target":"living","amount":-1,"when":"next_reset"}]');
  aid := (s->'amendments'->0->>'id')::uuid;
  s := public.tt_amend_cancel(rc, gen_random_uuid(), aid, 'Withdrawn after discussion.');
  perform pg_temp.ok(s->'amendments'->0->>'status' = 'cancelled' and (select jsonb_array_length(state->'pending') from public.tt_rooms where code = rc) = 0, 'scheduled amendment cancelled');
  perform pg_temp.fails(format('select public.tt_amend_cancel(%L, gen_random_uuid(), %L, %L)', rc, aid, 'again'), 'still scheduled');
  -- correction workflow: forward amendment that references the original
  s := public.tt_amend(rc, gen_random_uuid(), 'Cheap moves', 'Oops.', '[{"type":"set","key":"costMove","value":0}]'); aid := (s->'amendments'->0->>'id')::uuid;
  res := public.tt_amend_correction(rc, aid);
  perform pg_temp.ok(res->'effects' = '[{"key":"costMove","type":"set","value":2}]'::jsonb and jsonb_array_length(res->'caveats') >= 1, 'correction suggests the previous value and states its limits');
  s := public.tt_amend(rc, gen_random_uuid(), res->>'title', 'Reverting a typo.', res->'effects', null, aid);
  perform pg_temp.ok((s->'config'->>'costMove')::int = 2 and s->'amendments'->0->>'corrects' = aid::text and s->'events'->>0 like 'Correction by the host:%', 'correction recorded as a new public amendment');
  perform pg_temp.fails(format('select public.tt_amend(%L, gen_random_uuid(), %L, %L, %L::jsonb)', rc, 'Hearts', 'x', '[{"type":"set","key":"startHearts","value":5}]'), 'only change in the lobby');

  -- player proposals: private until approved, charged once on approval only
  perform public.tt_amend(rc, gen_random_uuid(), 'Attacks back on', 'Trial over.', '[{"type":"set","key":"allowAttack","value":true}]');
  perform pg_temp.pset(rc, 1, '{"points":4}'); perform pg_temp.be(b);
  perform pg_temp.fails(format('select public.tt_propose(%L, gen_random_uuid(), %L, %L, %L)', rc, 'Early', 'Too poor', 'house_rule'), 'You need 5 available points');
  perform pg_temp.pset(rc, 1, '{"points":6}');
  s := public.tt_propose(rc, gen_random_uuid(), 'Double shields', 'Shields should cost one.', 'house_rule'); pid := (s->'proposals'->0->>'id')::uuid;
  perform pg_temp.ok(pg_temp.pget(rc, 1, 'points') = '6' and jsonb_array_length(s->'proposals') = 1, 'submission costs nothing and reserves nothing');
  perform pg_temp.be(a); s := public.tt_view(rc);
  perform pg_temp.ok(jsonb_array_length(s->'proposals') = 0 and s::text not like '%Double shields%', 'pending proposal hidden from other players');
  perform pg_temp.pset(rc, 1, '{"points":4}'); perform pg_temp.be(h);
  res := public.tt_amend_preview(rc, '[{"type":"set","key":"costShield","value":1}]', pid);
  perform pg_temp.ok(not (res->>'ok')::boolean and res->'errors'->>0 like 'Proposer does not currently have%', 'preview rechecks the proposer''s balance');
  perform pg_temp.fails(format('select public.tt_amend(%L, gen_random_uuid(), %L, %L, %L::jsonb, %L)', rc, 'Double shields', 'ok', '[{"type":"set","key":"costShield","value":1}]', pid), 'Proposer needs 5 points. No charge or approval was made');
  perform pg_temp.ok(pg_temp.pget(rc, 1, 'points') = '4' and (select status from public.tt_proposals where id = pid) = 'pending' and (public.tt_view(rc)->'config'->>'costShield')::int = 2, 'failed approval: no charge, no effect, still pending');
  perform pg_temp.pset(rc, 1, '{"points":9}'); req := gen_random_uuid();
  s := public.tt_amend(rc, req, 'Double shields', 'Approved with a grant.', '[{"type":"set","key":"costShield","value":1},{"type":"adjust","resource":"hearts","target":"living","amount":1}]', pid);
  s := public.tt_amend(rc, req, 'Double shields', 'Approved with a grant.', '[{"type":"set","key":"costShield","value":1}]', pid);
  perform pg_temp.ok(pg_temp.pget(rc, 1, 'points') = '4' and pg_temp.pget(rc, 1, 'hearts') = '4' and (s->'config'->>'costShield')::int = 1
    and s->'amendments'->0->>'origin' = 'proposal' and s->'amendments'->0->>'proposerName' = 'The Baron'
    and s->'events'->>0 like 'Host approved a rule change: Double shields (proposed by The Baron)%', 'composed approval: payment + effects together, once, publicly attributed');
  perform pg_temp.fails(format('select public.tt_amend(%L, gen_random_uuid(), %L, %L, %L::jsonb, %L)', rc, 'Again', 'x', '[{"type":"written","text":"x"}]', pid), 'already reviewed');
  perform pg_temp.pset(rc, 1, '{"points":9}'); perform pg_temp.be(b); s := public.tt_propose_survivors(rc, gen_random_uuid(), 'Share it', 'Two of us win.', 2); pid := (s->'proposals'->0->>'id')::uuid;
  perform pg_temp.be(h); req := gen_random_uuid(); s := public.tt_review(rc, req, pid, 'reject', 'Not yet.');
  perform pg_temp.ok(pg_temp.pget(rc, 1, 'points') = '9' and s->'proposals'->0->>'status' = 'rejected', 'rejection is free');
  perform pg_temp.be(a); perform pg_temp.ok(public.tt_view(rc)::text not like '%Share it%', 'rejected proposal stays author-and-host private');
  -- shared victory through a survivor-threshold amendment; retry cannot end the game twice
  perform pg_temp.be(h); res := public.tt_amend_preview(rc, '[{"type":"set","key":"survivorGoal","value":3}]');
  perform pg_temp.ok((res->>'endsMatchNow')::boolean, 'preview warns that the amendment ends the match');
  req := gen_random_uuid(); s := public.tt_amend(rc, req, 'Three share it', 'Unanimous.', '[{"type":"set","key":"survivorGoal","value":3}]');
  s := public.tt_amend(rc, req, 'Three share it', 'Unanimous.', '[{"type":"set","key":"survivorGoal","value":3}]');
  perform pg_temp.ok(s->>'phase' = 'ended' and s->'winners' = '[0, 1, 4]'::jsonb and s->>'endedAt' is not null
    and (select count(*) from jsonb_array_elements_text(s->'events') where value like 'Game over.%') = 1, 'shared victory recorded once with every survivor');
  perform pg_temp.fails(format('select public.tt_amend(%L, gen_random_uuid(), %L, %L, %L::jsonb)', rc, 'Late', 'x', '[{"type":"set","key":"costMove","value":1}]'), 'match is complete');
  perform pg_temp.be(a); perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L)', rc, 'shield'), 'No active game');

  ------------------------------------------------------------------ G. Pacific clock, DST, catch-up (normal room, five real accounts)
  perform pg_temp.be(h); nrm := public.tt_create()->>'code';
  perform pg_temp.be(a); perform public.tt_join(nrm); perform pg_temp.be(b); perform public.tt_join(nrm); perform pg_temp.be(c); perform public.tt_join(nrm);
  perform pg_temp.be(d); perform public.tt_join(nrm); perform pg_temp.be(e); perform public.tt_join(nrm);
  perform pg_temp.be(h); perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L)', nrm, 'next_day'), 'automatic Pacific schedule');
  s := public.tt_command(nrm, gen_random_uuid(), 'start');
  perform pg_temp.ok(s->>'phase' = 'scheduled' and (s->>'closed')::boolean and (s->>'nextReset')::date = (clock_timestamp() at time zone 'America/Los_Angeles')::date + 1
    and not exists(select 1 from jsonb_array_elements(s->'players') where (value->>'points')::int <> 0), 'normal start: opens next Pacific midnight, no spendable point before then');
  perform pg_temp.be(a); perform pg_temp.fails(format('select public.tt_command(%L, gen_random_uuid(), %L)', nrm, 'shield'), 'No active game');
  -- DST start (2027-03-14): opening exactly once, 18:00 cutoff by Pacific wall clock
  update public.tt_rooms set state = jsonb_set(state, '{nextReset}', '"2027-03-14"') where code = nrm;
  perform public.tt_clock_apply(nrm, '2027-03-13 23:59:59 America/Los_Angeles'::timestamptz);
  perform pg_temp.ok(pg_temp.sget(nrm, 'phase') = 'scheduled' and pg_temp.pget(nrm, 0, 'points') = '0', 'nothing happens one second before midnight');
  perform public.tt_clock_apply(nrm, '2027-03-14 00:00:00 America/Los_Angeles'::timestamptz);
  perform public.tt_clock_apply(nrm, '2027-03-14 00:00:00 America/Los_Angeles'::timestamptz);
  perform public.tt_clock_apply(nrm, '2027-03-14 03:30:00 America/Los_Angeles'::timestamptz);
  perform pg_temp.ok(pg_temp.sget(nrm, 'phase') = 'active' and pg_temp.pget(nrm, 0, 'points') = '1' and pg_temp.sget(nrm, 'day') = '1'
    and pg_temp.sget(nrm, 'closed') = 'false' and pg_temp.sget(nrm, 'nextReset') = '2027-03-15', 'opening at 00:00 inclusive: one point, exactly once, across the DST jump');
  perform public.tt_clock_apply(nrm, '2027-03-14 17:59:59 America/Los_Angeles'::timestamptz);
  perform pg_temp.ok(pg_temp.sget(nrm, 'closed') = 'false', 'open until 17:59:59');
  perform public.tt_clock_apply(nrm, '2027-03-14 18:00:00 America/Los_Angeles'::timestamptz);
  perform pg_temp.ok(pg_temp.sget(nrm, 'closed') = 'true' and pg_temp.pget(nrm, 0, 'points') = '1', '18:00 exclusive cutoff');
  perform public.tt_clock_apply(nrm, '2027-03-15 00:00:05 America/Los_Angeles'::timestamptz);
  perform pg_temp.ok(pg_temp.pget(nrm, 0, 'points') = '2' and pg_temp.sget(nrm, 'day') = '2' and pg_temp.sget(nrm, 'closed') = 'false', 'daily income at the next midnight');
  -- missed job catch-up: three midnights at once; the ballot is settled by the first only
  perform pg_temp.pset(nrm, 4, '{"alive":false,"points":0}');
  update public.tt_rooms set state = jsonb_set(state, '{votes}', '{"4":0}') where code = nrm;
  perform public.tt_clock_apply(nrm, '2027-03-18 09:00:00 America/Los_Angeles'::timestamptz);
  perform pg_temp.ok(pg_temp.pget(nrm, 0, 'points') = '6' and pg_temp.pget(nrm, 1, 'points') = '5' and pg_temp.pget(nrm, 4, 'points') = '0'
    and pg_temp.sget(nrm, 'day') = '5' and pg_temp.sget(nrm, 'nextReset') = '2027-03-19', 'catch-up: every missed day once, one vote bonus, nothing for the eliminated');
  -- DST end (2027-11-07): the repeated 01:00 hour must not pay twice
  update public.tt_rooms set state = jsonb_set(state, '{nextReset}', '"2027-11-07"') where code = nrm;
  perform public.tt_clock_apply(nrm, '2027-11-07 01:30:00 America/Los_Angeles'::timestamptz);
  perform public.tt_clock_apply(nrm, '2027-11-07 09:30:00+00'::timestamptz);
  perform public.tt_clock_apply(nrm, '2027-11-07 17:59:00 America/Los_Angeles'::timestamptz);
  perform pg_temp.ok(pg_temp.pget(nrm, 0, 'points') = '7' and pg_temp.sget(nrm, 'closed') = 'false', 'fall-back day: one income, still open at 17:59');
  perform pg_temp.ok((select count(*) from public.tt_outbox where room = nrm and seat = 0 and category = 'income') = pg_temp.sget(nrm, 'rollovers')::int
    and pg_temp.sget(nrm, 'rollovers') = '6' and (select count(*) from public.tt_outbox where room = nrm and seat = 4 and category = 'income') = 2
    and (select count(*) from public.tt_outbox where room = nrm and seat = -1 and category = 'income') = 0
    and exists(select 1 from public.tt_outbox where room = nrm and seat = 2 and category = 'match' and dedupe = 'opened'), 'one income event per living seat per reset; none for the host');
  -- an action arriving after midnight is ordered after the reset (real clock): reset first, then the action
  update public.tt_rooms set state = state || jsonb_build_object('nextReset', ((clock_timestamp() at time zone 'America/Los_Angeles')::date)::text, 'rules', '{"cutoffHour":24}'::jsonb) where code = nrm;
  perform pg_temp.pset(nrm, 0, '{"x":0,"y":0}'); perform pg_temp.pset(nrm, 1, '{"x":0,"y":1,"hearts":1}'); perform pg_temp.pset(nrm, 2, '{"x":3,"y":3}'); perform pg_temp.pset(nrm, 3, '{"x":5,"y":5}');
  perform pg_temp.be(a); s := public.tt_command(nrm, gen_random_uuid(), 'attack', 1);
  perform pg_temp.ok(pg_temp.pget(nrm, 0, 'points') = '7' and pg_temp.sget(nrm, 'rollovers') = '7' and pg_temp.pget(nrm, 1, 'alive') = 'false'
    and exists(select 1 from public.tt_outbox where room = nrm and seat = 1 and category = 'eliminated'), 'midnight is applied before the action; elimination queued for that seat only');
  -- completion: last survivors, then no further income ever
  perform pg_temp.pset(nrm, 2, '{"alive":false}'); perform pg_temp.be(d); s := public.tt_command(nrm, gen_random_uuid(), 'remove');
  perform pg_temp.ok(s->>'phase' = 'ended' and s->'winners' = '[0]'::jsonb and s->'events'->>0 = 'Game over. Winner: Ada.' and (s->'players'->3->>'points')::int = 0, 'withdrawal is free and final; last survivor wins');
  select state into v from public.tt_rooms where code = nrm;
  perform public.tt_clock_apply(nrm, '2028-01-01 12:00:00 America/Los_Angeles'::timestamptz);
  perform pg_temp.ok(v = (select state from public.tt_rooms where code = nrm), 'no income or clock changes after completion');

  raise notice 'Release rule checks passed (% assertions). Fixtures roll back.', current_setting('tt.checks');
end;$$;
rollback;
