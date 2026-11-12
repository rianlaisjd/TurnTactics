-- Release upgrade 3 of 5. Run AFTER 021_notifications.sql. Safe to re-run.
-- One rules-profile model replaces the scattered "is slideshow?" constants. Existing rooms keep their
-- rules version; nothing in an existing room's state is rewritten by this file.
--   legacy-v0.5        rooms created before 016 (no rulesVersion stored)
--   slideshow-2026-11  rooms created by 016
--   owner-2026-11      NEW rooms: starting range 4, six players on 8 × 8, chess coordinates
-- An unknown version raises an error instead of silently falling back to legacy behaviour.
begin;

-- ---------- Profiles and resolved configuration ----------
create or replace function public.tt_rules_version(p_state jsonb) returns text
language sql immutable set search_path='' as $$ select coalesce(p_state->>'rulesVersion', 'legacy-v0.5') $$;

create or replace function public.tt_rules_profile(p_version text) returns jsonb
language plpgsql immutable set search_path='' as $$
declare base jsonb := jsonb_build_object(
  'costMove',1,'costAttack',1,'costShield',2,'costRange',2,'costProposal',5,
  'dailyIncome',1,'voteBonus',1,'baseRange',3,'maxRange',0,'startHearts',3,'shieldDays',1,'moveLimit',0,
  'cutoffHour',18,'allowMove',true,'allowAttack',true,'allowGive',true,'allowShield',true,'allowRange',true,
  -- Not amendable: structural behaviour of a rules version.
  'forfeitOnElimination',true,'lobbyPoints',0,'attributeProposals',true,'fixedBoard',true,'chessCoordinates',false);
begin
  if p_version = 'owner-2026-11' then
    return base || jsonb_build_object('baseRange',4,'chessCoordinates',true);
  elsif p_version = 'slideshow-2026-11' then
    return base;
  elsif p_version = 'legacy-v0.5' then
    return base || jsonb_build_object('costProposal',4,'baseRange',2,'cutoffHour',19,
      'forfeitOnElimination',false,'lobbyPoints',1,'attributeProposals',false,'fixedBoard',false);
  end if;
  raise exception 'Unsupported rules version "%". Install the matching migration before using this room', p_version;
end;$$;

-- Profile defaults overlaid with this room's approved amendments (state.rules).
create or replace function public.tt_rules(p_state jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select public.tt_rules_profile(public.tt_rules_version(p_state)) || coalesce(p_state->'rules', '{}'::jsonb)
$$;

-- Required board side, or NULL when the version does not fix one for that count.
create or replace function public.tt_board_size(p_version text, p_count int) returns int
language sql immutable set search_path='' as $$
  select case
    when p_version = 'owner-2026-11' then case
      when p_count between 5 and 6 then 8 when p_count = 7 then 9 when p_count between 8 and 9 then 10
      when p_count = 10 then 11 when p_count between 11 and 12 then 12 when p_count between 13 and 14 then 13
      when p_count between 15 and 16 then 14 when p_count between 17 and 20 then 15 end
    when p_version = 'slideshow-2026-11' then public.tt_slideshow_board(p_count)
  end
$$;

-- Kept for older callers; cost now comes from the resolved configuration.
create or replace function public.tt_proposal_cost(p_state jsonb) returns int
language sql immutable set search_path='' as $$ select (public.tt_rules(p_state)->>'costProposal')::int $$;

-- a1 is the lower-left square. Server rows count from the top, so rank = size - y.
create or replace function public.tt_square(p_state jsonb, p_x int, p_y int) returns text
language sql immutable set search_path='' as $$
  select case when (public.tt_rules(p_state)->>'chessCoordinates')::boolean
    then chr(97 + p_x) || ((p_state->>'size')::int - p_y)
    else '(' || (p_x + 1) || ', ' || (p_y + 1) || ')' end
$$;

-- The amendable settings. This is the single source for validation AND for the host's rules desk.
create or replace function public.tt_rules_catalog() returns jsonb
language sql immutable set search_path='' as $$ select jsonb_build_array(
  jsonb_build_object('key','costMove','group','Action costs','label','Move cost','type','int','min',0,'max',20,'unit','point(s)'),
  jsonb_build_object('key','costAttack','group','Action costs','label','Attack cost','type','int','min',0,'max',20,'unit','point(s)'),
  jsonb_build_object('key','costShield','group','Action costs','label','Shield cost','type','int','min',0,'max',20,'unit','point(s)'),
  jsonb_build_object('key','costRange','group','Action costs','label','Range upgrade cost','type','int','min',0,'max',20,'unit','point(s)'),
  jsonb_build_object('key','costProposal','group','Action costs','label','Rule proposal cost','type','int','min',0,'max',50,'unit','point(s)',
    'note','Applies to proposals approved after this amendment.'),
  jsonb_build_object('key','dailyIncome','group','Income','label','Daily income','type','int','min',0,'max',20,'unit','point(s) per living player',
    'note','Changes income from the next midnight reset. No points are granted now.'),
  jsonb_build_object('key','voteBonus','group','Income','label','Eliminated-player vote bonus','type','int','min',0,'max',10,'unit','point(s)'),
  jsonb_build_object('key','baseRange','group','Range','label','Base targeting range','type','int','min',1,'max',30,'unit','',
    'note','Every player''s current range shifts by the same difference. Purchased upgrades are kept.'),
  jsonb_build_object('key','maxRange','group','Range','label','Targeting range cap','type','int','min',0,'max',30,'unit','','zero','no cap',
    'note','Upgrades above the cap are kept but have no effect while the cap stands.'),
  jsonb_build_object('key','moveLimit','group','Movement','label','Moves per player per day','type','int','min',0,'max',20,'unit','','zero','unlimited',
    'note','Moves already made today count toward a new limit.'),
  jsonb_build_object('key','shieldDays','group','Shield','label','Shield duration','type','int','min',1,'max',7,'unit','midnight reset(s)',
    'note','Applies to shields raised after this amendment. Shields already active keep their current expiry.'),
  jsonb_build_object('key','startHearts','group','Hearts','label','Starting hearts','type','int','min',1,'max',10,'unit','',
    'note','Lobby only. In a running game use a heart adjustment instead.'),
  jsonb_build_object('key','survivorGoal','group','Victory','label','Survivors who share victory','type','int','min',1,'max',20,'unit','',
    'note','If that many or fewer players are alive, the match ends as soon as this takes effect.'),
  jsonb_build_object('key','cutoffHour','group','Schedule','label','Daily action cutoff (Pacific hour)','type','int','min',1,'max',24,'unit',':00',
    'note','Actions are open from midnight until this hour. 24 keeps actions open all day. Test rooms use manual controls.'),
  jsonb_build_object('key','allowMove','group','Action availability','label','Moves','type','bool'),
  jsonb_build_object('key','allowAttack','group','Action availability','label','Attacks','type','bool'),
  jsonb_build_object('key','allowGive','group','Action availability','label','Point transfers','type','bool'),
  jsonb_build_object('key','allowShield','group','Action availability','label','Shields','type','bool'),
  jsonb_build_object('key','allowRange','group','Action availability','label','Range upgrades','type','bool')
) $$;

-- ---------- Amendment records ----------
create table if not exists public.tt_amendments (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity unique,
  room text not null references public.tt_rooms(code) on delete cascade,
  origin text not null check (origin in ('host','proposal')),
  proposal uuid references public.tt_proposals(id) on delete set null,
  proposer_name text,
  title text not null check (length(title) between 1 and 80),
  reason text not null check (length(reason) between 1 and 500),
  effects jsonb not null, lines jsonb not null, undo jsonb not null default '[]'::jsonb,
  status text not null default 'applied' check (status in ('applied','scheduled','cancelled')),
  corrects uuid references public.tt_amendments(id) on delete set null,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists tt_amendments_room_seq on public.tt_amendments(room, seq);
alter table public.tt_amendments enable row level security;
revoke all on public.tt_amendments from public, anon, authenticated;
revoke all on sequence public.tt_amendments_seq_seq from public, anon, authenticated;

-- ---------- Pure helpers over a room's state ----------
-- Ends the match when 1..goal players remain. Never ends twice; never invents a winner from zero survivors.
create or replace function public.tt_finish_state(p_state jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare s jsonb := p_state; ids jsonb; names text; n int; goal int := coalesce((p_state->>'survivorGoal')::int, 1);
begin
  if s->>'phase' <> 'active' then return s; end if;
  select count(*), coalesce(jsonb_agg((value->>'id')::int order by (value->>'id')::int), '[]'::jsonb),
         string_agg(value->>'name', ', ' order by (value->>'id')::int)
    into n, ids, names from jsonb_array_elements(s->'players') where (value->>'alive')::boolean;
  if n > 0 and n <= goal then
    s := s || jsonb_build_object('phase','ended','closed',true,'winners',ids,'winner',ids->0,'endedAt',clock_timestamp(),
                                 'pending','[]'::jsonb);
    s := jsonb_set(s, '{events}', jsonb_build_array('Game over. Winner' || case when n = 1 then '' else 's' end
           || ': ' || names || '.') || (s->'events'));
  end if;
  return s;
end;$$;

-- Validates and (for immediate effects) applies a list of typed effects to a state. No table access,
-- so the same code serves the preview, the atomic apply, and scheduled application at a reset.
-- Returns {state, lines[], errors[], warnings[], later[], undo[], caveats[]}.
create or replace function public.tt_amend_eval(p_state jsonb, p_effects jsonb, p_force_now boolean default false) returns jsonb
language plpgsql immutable set search_path='' as $$
declare s jsonb := p_state; cfg jsonb; cat jsonb; e jsonb; lines jsonb := '[]'; errors jsonb := '[]'; warnings jsonb := '[]';
  later jsonb := '[]'; undo jsonb := '[]'; caveats jsonb := '[]'; seen text[] := '{}';
  typ text; due text; k text; v jsonb; old_v jsonb; nv int; ov int; phase text := p_state->>'phase'; delta int;
  ps jsonb; item jsonb; i int; res text; amt int; tgt jsonb; seat int; who text; line text; living int; err text;
  forfeit boolean; is_now boolean; unit text;
begin
  if p_effects is null or jsonb_typeof(p_effects) <> 'array' or jsonb_array_length(p_effects) = 0 then
    return jsonb_build_object('state',s,'lines',lines,'errors',jsonb_build_array('Add at least one effect'),'warnings',warnings,'later',later,'undo',undo,'caveats',caveats);
  end if;
  if jsonb_array_length(p_effects) > 12 then
    return jsonb_build_object('state',s,'lines',lines,'errors',jsonb_build_array('An amendment can contain at most 12 effects'),'warnings',warnings,'later',later,'undo',undo,'caveats',caveats);
  end if;
  if phase = 'ended' then
    return jsonb_build_object('state',s,'lines',lines,'errors',jsonb_build_array('This match is complete; its rules can no longer change'),'warnings',warnings,'later',later,'undo',undo,'caveats',caveats);
  end if;
  for e in select value from jsonb_array_elements(p_effects) loop
    err := null; line := null; cfg := public.tt_rules(s); ps := s->'players';
    forfeit := (cfg->>'forfeitOnElimination')::boolean;
    typ := e->>'type'; due := coalesce(e->>'when', 'now'); is_now := p_force_now or due = 'now';
    if jsonb_typeof(e) <> 'object' or typ is null or typ not in ('set','adjust','expire_shields','written') then
      err := 'Unsupported effect type';
    elsif due not in ('now','next_reset') then err := 'Unsupported timing';
    elsif due = 'next_reset' and not p_force_now and phase = 'lobby' then
      err := 'Scheduled effects need a scheduled or running game. In the lobby, apply the change now';
    elsif typ = 'set' then
      k := e->>'key'; v := e->'value';
      select value into cat from jsonb_array_elements(public.tt_rules_catalog()) where value->>'key' = k;
      if cat is null then err := 'Unsupported setting';
      elsif k = any(seen) then err := (cat->>'label') || ' is set more than once in this amendment';
      elsif cat->>'type' = 'bool' then
        if jsonb_typeof(v) <> 'boolean' then err := (cat->>'label') || ' must be on or off';
        else
          old_v := cfg->k;
          if old_v = v then err := (cat->>'label') || ' is already ' || case when v::boolean then 'enabled' else 'disabled' end;
          else line := (cat->>'label') || ' ' || case when v::boolean then 'are enabled.' else 'are disabled. A disabled action is rejected without charge.' end;
          end if;
        end if;
      else
        if jsonb_typeof(v) <> 'number' or (v::text) !~ '^-?[0-9]{1,4}$' then err := (cat->>'label') || ' must be a whole number';
        else
          nv := (v::text)::int; ov := case when k = 'survivorGoal' then coalesce((s->>'survivorGoal')::int, 1) else (cfg->>k)::int end;
          old_v := to_jsonb(ov); unit := coalesce(nullif(cat->>'unit',''), '');
          if nv < (cat->>'min')::int or nv > (cat->>'max')::int then
            err := (cat->>'label') || ' must be between ' || (cat->>'min') || ' and ' || (cat->>'max');
          elsif nv = ov then err := (cat->>'label') || ' is already ' || nv;
          elsif k = 'startHearts' and phase <> 'lobby' then
            err := 'Starting hearts can only change in the lobby. Use a heart adjustment in a running game';
          elsif k = 'survivorGoal' and nv > greatest(jsonb_array_length(ps), case when phase = 'lobby' then 20 else 0 end) then
            err := 'The survivor target cannot exceed the number of players';
          elsif k = 'maxRange' and nv <> 0 and nv < 1 then err := 'Range cap must be at least 1';
          else
            line := (cat->>'label') || ': ' ||
              case when ov = 0 and cat ? 'zero' and cat->>'zero' <> '' then cat->>'zero' else ov::text end || ' → ' ||
              case when nv = 0 and cat ? 'zero' and cat->>'zero' <> '' then cat->>'zero' else nv::text end ||
              case when unit <> '' and not (nv = 0 and cat ? 'zero') then case when unit = ':00' then ':00' else ' ' || unit end else '' end || '.' ||
              coalesce(' ' || (cat->>'note'), '');
          end if;
        end if;
      end if;
      if err is null then
        seen := seen || k;
        if is_now then
          undo := undo || jsonb_build_array(jsonb_build_object('type','set','key',k,'value',old_v));
          if k = 'survivorGoal' then s := jsonb_set(s, '{survivorGoal}', v);
          else s := jsonb_set(s, '{rules}', coalesce(s->'rules','{}'::jsonb) || jsonb_build_object(k, v));
          end if;
          if k in ('baseRange','startHearts') then
            delta := nv - ov;
            for i in 0..jsonb_array_length(ps)-1 loop
              item := ps->i;
              if k = 'baseRange' then item := item || jsonb_build_object('range', greatest(1, (item->>'range')::int + delta));
              else item := item || jsonb_build_object('hearts', nv); end if;
              ps := jsonb_set(ps, array[i::text], item);
            end loop;
            s := jsonb_set(s, '{players}', ps);
          end if;
        end if;
      end if;
    elsif typ = 'adjust' then
      res := e->>'resource'; tgt := e->'target';
      if res is null or res not in ('points','hearts','range') then err := 'Choose points, hearts or range';
      elsif jsonb_typeof(e->'amount') <> 'number' or (e->>'amount') !~ '^-?[0-9]{1,3}$' or (e->>'amount')::int = 0
            or abs((e->>'amount')::int) > 50 then err := 'Adjustment amount must be a whole number from 1 to 50';
      elsif phase not in ('active','scheduled') or (is_now and not p_force_now and phase <> 'active') then
        err := 'Resource adjustments need a running game' || case when phase = 'scheduled' then '. Schedule it for the next reset instead' else '' end;
      elsif not coalesce(tgt = '"living"'::jsonb or (jsonb_typeof(tgt) = 'number' and (tgt::text) ~ '^[0-9]{1,2}$'), false) then
        err := 'Choose every living player or one living player';
      else
        amt := (e->>'amount')::int; seat := case when jsonb_typeof(tgt) = 'number' then (tgt::text)::int end;
        if seat is not null then
          select value->>'name' into who from jsonb_array_elements(ps) where (value->>'id')::int = seat and (value->>'alive')::boolean;
          if who is null then err := 'That player is not alive in this room'; end if;
        end if;
        if err is null then
          line := case when seat is null then 'Every living player ' else who || ' ' end
            || case when amt > 0 then 'gains ' else 'loses ' end
            || abs(amt) || ' ' || case res when 'points' then 'point' when 'hearts' then 'heart' else 'range' end
            || case when abs(amt) = 1 or res = 'range' then '' else 's' end || '.'
            || case when res = 'points' and amt < 0 then ' Balances cannot go below zero.'
                    when res = 'hearts' and amt < 0 then ' Shields do not block this. Anyone reduced to zero hearts is eliminated.'
                    when res = 'range' and amt < 0 then ' Range cannot go below 1.' else '' end;
          if is_now then
            for i in 0..jsonb_array_length(ps)-1 loop
              item := ps->i;
              continue when not (item->>'alive')::boolean or (seat is not null and (item->>'id')::int <> seat);
              if res = 'points' then item := item || jsonb_build_object('points', greatest(0, (item->>'points')::int + amt));
              elsif res = 'range' then item := item || jsonb_build_object('range', greatest(1, (item->>'range')::int + amt));
              else
                item := item || jsonb_build_object('hearts', greatest(0, (item->>'hearts')::int + amt));
                if (item->>'hearts')::int = 0 then
                  item := item || jsonb_build_object('alive', false, 'shield', false, 'shieldDays', 0);
                  if forfeit then item := item || jsonb_build_object('points', 0); end if;
                end if;
              end if;
              ps := jsonb_set(ps, array[i::text], item);
            end loop;
            select count(*) into living from jsonb_array_elements(ps) where (value->>'alive')::boolean;
            if living = 0 then err := 'This would eliminate every living player, leaving no winner';
            else
              s := jsonb_set(s, '{players}', ps);
              undo := undo || jsonb_build_array(jsonb_build_object('type','adjust','resource',res,'target',tgt,'amount',-amt));
              if amt < 0 then caveats := caveats || jsonb_build_array('Reversing a ' || res || ' deduction does not revive eliminated players or restore amounts lost to the zero floor.'); end if;
            end if;
          end if;
        end if;
      end if;
    elsif typ = 'expire_shields' then
      if phase <> 'active' and not (due = 'next_reset' and phase = 'scheduled') then err := 'Ending shields needs a running game';
      else
        line := 'All active shields end' || case when is_now then ' now.' else ' at the reset.' end;
        if is_now then
          for i in 0..jsonb_array_length(ps)-1 loop
            ps := jsonb_set(ps, array[i::text], (ps->i) || jsonb_build_object('shield', false, 'shieldDays', 0));
          end loop;
          s := jsonb_set(s, '{players}', ps);
          caveats := caveats || jsonb_build_array('Ended shields cannot be restored by a correction; players would need to raise them again.');
        end if;
      end if;
    else -- written
      if due <> 'now' then err := 'A written rule takes effect when it is published';
      elsif length(trim(coalesce(e->>'text',''))) not between 1 and 500 then err := 'Write the host-enforced rule in 1–500 characters';
      else
        line := 'Host-enforced written rule: ' || trim(e->>'text');
        undo := undo || jsonb_build_array(jsonb_build_object('type','written','text', left('Withdrawn: ' || trim(e->>'text'), 500)));
      end if;
    end if;
    if err is not null then
      if p_force_now then warnings := warnings || jsonb_build_array('Skipped: ' || err);
      else errors := errors || jsonb_build_array(err); end if;
    else
      lines := lines || jsonb_build_array(jsonb_build_object('text', line, 'when', case when is_now then 'now' else 'next_reset' end,
        'hostEnforced', typ = 'written'));
      if not is_now then later := later || jsonb_build_array(e); end if;
    end if;
  end loop;
  return jsonb_build_object('state', s, 'lines', lines, 'errors', errors, 'warnings', warnings, 'later', later, 'undo', undo, 'caveats', caveats);
end;$$;

-- One midnight reset (or the opening). Order: settle votes → expire shields/reset move counters →
-- scheduled amendments → income. Temporary keys _applied/_bonus/_notes are consumed by the caller.
create or replace function public.tt_rollover(p_state jsonb, p_opening boolean) returns jsonb
language plpgsql immutable set search_path='' as $$
declare s jsonb := p_state; ps jsonb := p_state->'players'; cfg jsonb; item jsonb; i int; counts jsonb := '{}'; total int := 0;
  bonus text; v record; n int; keep jsonb := '[]'; applied jsonb := '[]'; notes jsonb := '[]'; p jsonb; res jsonb; left_days int; event text;
begin
  if not p_opening then
    for v in select * from jsonb_each_text(coalesce(s->'votes','{}'::jsonb)) loop
      -- Only an eliminated voter's ballot for a still-living player counts.
      if exists(select 1 from jsonb_array_elements(ps) where value->>'id' = v.key and not (value->>'alive')::boolean)
         and exists(select 1 from jsonb_array_elements(ps) where value->>'id' = v.value and (value->>'alive')::boolean) then
        counts := jsonb_set(counts, array[v.value], to_jsonb(coalesce((counts->>v.value)::int, 0) + 1)); total := total + 1;
      end if;
    end loop;
    select key into bonus from jsonb_each_text(counts) where value::int * 2 > total;
  end if;
  for i in 0..jsonb_array_length(ps)-1 loop
    item := ps->i;
    left_days := case when coalesce((item->>'shield')::boolean, false) then coalesce((item->>'shieldDays')::int, 1) - 1 else 0 end;
    item := item || jsonb_build_object('shield', left_days > 0, 'shieldDays', greatest(left_days, 0), 'movesToday', 0);
    ps := jsonb_set(ps, array[i::text], item);
  end loop;
  n := coalesce((s->>'rollovers')::int, 0) + 1;
  s := s || jsonb_build_object('players', ps, 'rollovers', n);
  for p in select value from jsonb_array_elements(coalesce(s->'pending','[]'::jsonb)) loop
    if (p->>'applyAt')::int <= n then
      res := public.tt_amend_eval(s || jsonb_build_object('phase','active'), p->'effects', true);
      s := (res->'state') || jsonb_build_object('phase', s->>'phase');
      applied := applied || jsonb_build_array(p->'id');
      notes := notes || jsonb_build_array('Scheduled rule amendment took effect: ' || (p->>'title') || ' — '
        || coalesce((select string_agg(value->>'text', ' ') from jsonb_array_elements(res->'lines')), 'no effect')
        || coalesce((select ' ' || string_agg(value #>> '{}', ' ') from jsonb_array_elements(res->'warnings')), ''));
    else keep := keep || jsonb_build_array(p);
    end if;
  end loop;
  cfg := public.tt_rules(s); ps := s->'players';
  for i in 0..jsonb_array_length(ps)-1 loop
    item := ps->i;
    if (item->>'alive')::boolean then
      item := item || jsonb_build_object('points', (item->>'points')::int + (cfg->>'dailyIncome')::int
        + case when item->>'id' = bonus then (cfg->>'voteBonus')::int else 0 end);
      ps := jsonb_set(ps, array[i::text], item);
    end if;
  end loop;
  s := s || jsonb_build_object('players', ps, 'phase', 'active', 'pending', keep, 'votes', '{}'::jsonb,
    'day', (s->>'day')::int + case when p_opening then 0 else 1 end);
  event := case when p_opening then 'The field opened at midnight Pacific. Opening income awarded.'
                else 'Day ' || (s->>'day') || ' began. Daily income awarded; expired shields ended.' end;
  s := jsonb_set(s, '{events}', (select coalesce(jsonb_agg(value), '[]'::jsonb) from (
         select value from jsonb_array_elements(notes) with ordinality t(value, o) order by o desc) x)
       || jsonb_build_array(event) || (s->'events'));
  return s || jsonb_build_object('_applied', applied, '_bonus', to_jsonb(bonus));
end;$$;

-- Writes a changed state: victory check, then outbox events derived from the before/after difference.
create or replace function public.tt_commit(p_code text, p_before jsonb, p_after jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s jsonb := public.tt_finish_state(p_after - '_applied' - '_bonus'); a jsonb; test_room boolean := coalesce((p_after->>'isTest')::boolean, false);
begin
  update public.tt_rooms set state = s where code = p_code;
  if s->>'phase' = 'ended' then update public.tt_amendments set status = 'cancelled' where room = p_code and status = 'scheduled'; end if;
  if test_room then return s; end if;
  for a in select value from jsonb_array_elements(s->'players') loop
    if not (a->>'alive')::boolean and not coalesce((a->>'isTestSeat')::boolean, false)
       and exists(select 1 from jsonb_array_elements(p_before->'players') b where b->>'id' = a->>'id' and (b->>'alive')::boolean) then
      perform public.tt_notify(p_code, (a->>'id')::int, 'eliminated', 'eliminated');
    end if;
  end loop;
  if s->>'phase' = 'ended' and p_before->>'phase' <> 'ended' then
    perform public.tt_notify_room(p_code, s, 'match', 'ended');
  elsif s->>'phase' = 'active' and p_before->>'phase' = 'scheduled' then
    perform public.tt_notify_room(p_code, s, 'match', 'opened');
  end if;
  return s;
end;$$;

-- Trusted clock. NOT executable by clients. p_now exists for admin tests only.
create or replace function public.tt_clock_apply(p_code text, p_now timestamptz default clock_timestamp()) returns void
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; before jsonb; local_now timestamp; today date; due date; cutoff int; applied jsonb; first_run boolean := true;
begin
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then return; end if;
  s := r.state; before := s;
  if coalesce((s->>'isTest')::boolean, false) or s->>'phase' not in ('active','scheduled') then return; end if;
  local_now := p_now at time zone 'America/Los_Angeles'; today := local_now::date;
  -- A room without a reset date starts accounting from the next local midnight: no retroactive income.
  due := coalesce((s->>'nextReset')::date, today + 1);
  while due <= today loop
    -- Each missed midnight is processed exactly once, in order. Ballots are consumed by the first.
    s := public.tt_rollover(s, s->>'phase' = 'scheduled');
    applied := s->'_applied';
    if jsonb_array_length(applied) > 0 then
      update public.tt_amendments set status = 'applied' where room = r.code and status = 'scheduled'
        and id in (select (value #>> '{}')::uuid from jsonb_array_elements(applied));
      perform public.tt_notify_room(r.code, s, 'rules', 'rules:' || (s->>'rollovers'));
    end if;
    perform public.tt_notify_room(r.code, s, 'income', 'income:' || (s->>'rollovers'), false, true);
    if s->>'_bonus' is not null then perform public.tt_notify(r.code, (s->>'_bonus')::int, 'bonus', 'bonus:' || (s->>'rollovers')); end if;
    s := jsonb_set(s - '_applied' - '_bonus', '{hostLog}', jsonb_build_array(p_now::text || ' · Midnight reset processed for ' || due::text
      || case when s->>'_bonus' is not null then '; vote bonus awarded to seat ' || ((s->>'_bonus')::int + 1) else '' end || '.') || (s->'hostLog'));
    s := public.tt_finish_state(s);
    due := due + 1;
    exit when s->>'phase' = 'ended';
  end loop;
  if s->>'phase' <> 'ended' then
    cutoff := (public.tt_rules(s)->>'cutoffHour')::int;
    s := s || jsonb_build_object('nextReset', due::text,
      'closed', s->>'phase' = 'scheduled' or extract(hour from local_now)::int >= cutoff);
  end if;
  if s is distinct from r.state then perform public.tt_commit(r.code, before, s); end if;
end;$$;

create or replace function public.tt_finish_if_ready(p_code text) returns void
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb;
begin
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then return; end if; s := r.state;
  if s->>'phase' = 'ended' then
    -- Older finished rooms: add the winners list and a retention start, once.
    if s->'winners' is null and s->>'winner' is not null then s := jsonb_set(s, '{winners}', jsonb_build_array((s->>'winner')::int)); end if;
    if s->'endedAt' is null then s := jsonb_set(s, '{endedAt}', to_jsonb(clock_timestamp())); end if;
    if s is distinct from r.state then update public.tt_rooms set state = s where code = r.code; end if;
    return;
  end if;
  if public.tt_finish_state(s) is distinct from s then perform public.tt_commit(r.code, s, s); end if;
end;$$;

-- ---------- Projection ----------
create or replace function public.tt_view_core(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; mine jsonb; players jsonb; host_view boolean; visible_proposals jsonb;
  approved_rules jsonb; amendments jsonb; cfg jsonb; attribute boolean; ended timestamptz;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code));
  if not found then raise exception 'Room unavailable'; end if;
  s := r.state; host_view := r.host = auth.uid();
  select value into mine from jsonb_array_elements(s->'players') where value->>'uid' = auth.uid()::text;
  if not host_view and mine is null then raise exception 'Room unavailable'; end if;
  perform public.tt_finish_if_ready(r.code); select state into s from public.tt_rooms where code = r.code;
  cfg := public.tt_rules(s); attribute := (cfg->>'attributeProposals')::boolean; ended := (s->>'endedAt')::timestamptz;
  -- Other players' hearts, points, range and shield never leave the backend. Account UUIDs never do.
  select coalesce(jsonb_agg(case when host_view or value->>'uid' = auth.uid()::text then value - 'uid' else
    jsonb_build_object('id',value->'id','name',value->'name','x',value->'x','y',value->'y','alive',value->'alive','icon',value->'icon',
      'isTestSeat',coalesce(value->'isTestSeat','false'::jsonb)) end order by (value->>'id')::int), '[]'::jsonb)
    into players from jsonb_array_elements(s->'players');
  select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'title',q.title,'body',q.body,'kind',q.kind,'survivorCount',q.survivor_count,
      'status',q.status,'reason',q.reason,
      'authorName',coalesce((select a->>'name' from jsonb_array_elements(s->'players') a where a->>'uid' = q.author::text),'Player'),
      'createdAt',q.created_at,'reviewedAt',q.reviewed_at) order by q.created_at desc), '[]'::jsonb)
    into visible_proposals from public.tt_proposals q where q.room = r.code and (host_view or q.author = auth.uid());
  select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'title',q.title,'body',q.body,'kind',q.kind,'survivorCount',q.survivor_count,
      'authorName',case when attribute then coalesce((select a->>'name' from jsonb_array_elements(s->'players') a where a->>'uid' = q.author::text),'Player') end,
      'reviewedAt',q.reviewed_at) order by q.reviewed_at), '[]'::jsonb)
    into approved_rules from public.tt_proposals q where q.room = r.code and q.status = 'approved';
  select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'origin',m.origin,'title',m.title,'reason',m.reason,'lines',m.lines,
      'status',m.status,'proposerName',case when attribute then m.proposer_name end,'corrects',m.corrects,'createdAt',m.created_at)
      order by m.seq desc), '[]'::jsonb)
    into amendments from public.tt_amendments m where m.room = r.code;
  return jsonb_build_object('code',r.code,'invite',r.invite,'rulesVersion',public.tt_rules_version(s),'config',cfg,
    'proposalCost',(cfg->>'costProposal')::int,'cutoffHour',(cfg->>'cutoffHour')::int,'baseRange',(cfg->>'baseRange')::int,
    'requiredBoardSize',public.tt_board_size(public.tt_rules_version(s), jsonb_array_length(s->'players')),
    'timezone','America/Los_Angeles','nextReset',s->'nextReset','serverTime',clock_timestamp(),
    'isTest',coalesce(s->'isTest','false'::jsonb),'isHost',host_view,'me',mine->'id','phase',s->'phase','day',s->'day','size',s->'size',
    'closed',s->'closed','survivorGoal',coalesce((s->>'survivorGoal')::int,1),'winners',coalesce(s->'winners','[]'::jsonb),'winner',s->'winner',
    'endedAt',ended,'chatExpiresAt',ended + interval '24 hours',
    'players',players,'proposals',visible_proposals,'rules',approved_rules,'amendments',amendments,
    'events',(select coalesce(jsonb_agg(value order by o), '[]'::jsonb) from jsonb_array_elements(s->'events') with ordinality t(value, o) where o <= 300),
    'hostLog',case when host_view then (select coalesce(jsonb_agg(value order by o), '[]'::jsonb)
       from jsonb_array_elements(s->'hostLog') with ordinality t(value, o) where o <= 300) else '[]'::jsonb end);
end;$$;

-- ---------- Rooms and seats ----------
create or replace function public.tt_create() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c text; n int;
begin
  perform public.tt_require_account();
  select count(*) into n from public.tt_rooms where host = auth.uid();
  if n >= 5 then raise exception 'Limit: five rooms per host. Delete a finished room from its host desk first'; end if;
  loop
    c := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    begin
      insert into public.tt_rooms(code, host, state) values (c, auth.uid(), jsonb_build_object('rulesVersion','owner-2026-11',
        'phase','lobby','day',1,'size',8,'closed',false,'winner',null,'players','[]'::jsonb,'votes','{}'::jsonb,
        'events','[]'::jsonb,'hostLog','[]'::jsonb,'rules','{}'::jsonb,'pending','[]'::jsonb,'rollovers',0));
      exit;
    exception when unique_violation then null;
    end;
  end loop;
  perform public.tt_assign_invite(c);
  return public.tt_view(c);
end;$$;

-- p_name is optional: the account display name is the default; a non-empty value is a room-specific name.
-- An unknown, closed or full invitation returns {"error": ...} so the failed attempt is recorded.
create or replace function public.tt_join(p_code text, p_name text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; n int; player jsonb; c text; cfg jsonb; shown text; account_name text;
  generic constant text := 'That invitation is not available. Check the code with your host; rooms close to new players once scheduled';
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  c := public.tt_room_code(p_code);
  if c is not null then
    select * into r from public.tt_rooms where code = c for update; s := r.state;
    -- An existing member (including a preserved anonymous seat) simply re-enters.
    if r.host = auth.uid() or exists(select 1 from jsonb_array_elements(s->'players') where value->>'uid' = auth.uid()::text) then
      return public.tt_view(r.code);
    end if;
  end if;
  account_name := public.tt_require_account();
  if public.tt_join_blocked() then raise exception 'Too many attempts. Wait ten minutes and try again'; end if;
  if c is null or s->>'phase' <> 'lobby' or jsonb_array_length(s->'players') >= 20 then
    perform public.tt_join_failed(); return jsonb_build_object('error', generic);
  end if;
  shown := coalesce(nullif(trim(coalesce(p_name,'')), ''), account_name);
  if length(shown) not between 1 and 24 then raise exception 'Use a name of 1–24 characters'; end if;
  if public.tt_name_reserved(shown) then raise exception 'That name is reserved. Choose another room name'; end if;
  if exists(select 1 from jsonb_array_elements(s->'players') where lower(value->>'name') = lower(shown)) then
    raise exception 'That name is already used in this room. Choose a room-specific name';
  end if;
  cfg := public.tt_rules(s); n := jsonb_array_length(s->'players');
  player := jsonb_build_object('id',n,'uid',auth.uid(),'name',shown,'x',null,'y',null,'hearts',(cfg->>'startHearts')::int,
    'points',(cfg->>'lobbyPoints')::int,'range',(cfg->>'baseRange')::int,'shield',false,'alive',true);
  s := jsonb_set(s, '{players}', (s->'players') || jsonb_build_array(player));
  update public.tt_rooms set state = s where code = r.code;
  return public.tt_view(r.code);
end;$$;

create or replace function public.tt_set_room_name(p_code text, p_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; idx int; shown text := trim(coalesce(p_name,''));
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if; s := r.state;
  select (ord-1)::int into idx from jsonb_array_elements(s->'players') with ordinality a(value, ord) where value->>'uid' = auth.uid()::text;
  if idx is null then raise exception 'Only a player can set a room name'; end if;
  if s->'players'->idx->>'name' = shown then return public.tt_view(r.code); end if;
  if s->>'phase' <> 'lobby' then raise exception 'Room names are fixed once the game is scheduled'; end if;
  if length(shown) not between 1 and 24 then raise exception 'Use a name of 1–24 characters'; end if;
  if public.tt_name_reserved(shown) then raise exception 'That name is reserved. Choose another room name'; end if;
  if exists(select 1 from jsonb_array_elements(s->'players') where lower(value->>'name') = lower(shown) and value->>'uid' <> auth.uid()::text) then
    raise exception 'That name is already used in this room';
  end if;
  update public.tt_rooms set state = jsonb_set(s, array['players', idx::text, 'name'], to_jsonb(shown)) where code = r.code;
  return public.tt_view(r.code);
end;$$;

create or replace function public.tt_fill_test_seats(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; ps jsonb; n int; i int; seat jsonb; cfg jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  if r.host <> auth.uid() then raise exception 'Host only'; end if;
  s := r.state; cfg := public.tt_rules(s);
  if s->>'phase' <> 'lobby' then raise exception 'Test seats can only be added before starting'; end if;
  ps := s->'players'; n := jsonb_array_length(ps);
  if not exists(select 1 from jsonb_array_elements(ps) where coalesce((value->>'isTestSeat')::boolean, false) = false) then
    raise exception 'A real player must join first';
  end if;
  -- Idempotent: a retry never adds duplicate seats or repeats the announcement.
  if coalesce((s->>'isTest')::boolean, false) and n >= 5 then return public.tt_view(r.code); end if;
  if n >= 5 then raise exception 'This lobby already has five players; test seats are unnecessary'; end if;
  for i in n..4 loop
    seat := jsonb_build_object('id',i,'uid','test:' || gen_random_uuid()::text,
      'name','Test seat ' || (i+1) || ' [' || substr(gen_random_uuid()::text, 1, 4) || ']','isTestSeat',true,'x',null,'y',null,
      'hearts',(cfg->>'startHearts')::int,'points',(cfg->>'lobbyPoints')::int,'range',(cfg->>'baseRange')::int,'shield',false,'alive',true);
    ps := ps || jsonb_build_array(seat);
  end loop;
  s := s || jsonb_build_object('players', ps, 'isTest', true);
  s := jsonb_set(s, '{events}', jsonb_build_array('TEST ROOM: placeholder seats added. Not a competitive game.') || (s->'events'));
  s := jsonb_set(s, '{hostLog}', jsonb_build_array('Host filled empty seats for testing.') || (s->'hostLog'));
  update public.tt_rooms set state = s where code = r.code;
  return public.tt_view(r.code);
end;$$;

-- ---------- Actions ----------
drop function if exists public.tt_command_core(text,uuid,text,int,text,int);
create or replace function public.tt_command(p_code text, p_request uuid, p_action text, p_target int default null,
  p_direction text default null, p_size int default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; before jsonb; ps jsonb; cfg jsonb; actor jsonb; target jsonb; item jsonb;
  idx int; tidx int; i int; n int; side int; need int; cells int[]; cell int; cost int; dx int; dy int; newx int; newy int;
  public_event text; detail text; is_host boolean; is_test boolean; reach int; lim int; cap int; forfeit boolean; due date; ver text;
begin
  if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  if r.host <> auth.uid() and not exists(select 1 from jsonb_array_elements(r.state->'players') where value->>'uid' = auth.uid()::text) then
    raise exception 'Room unavailable';
  end if;
  -- Accepted request IDs are checked before validation, so a retry stays a no-op across phase/time changes.
  if exists(select 1 from public.tt_requests where room = r.code and user_id = auth.uid() and request_id = p_request) then
    return public.tt_view(r.code);
  end if;
  -- The room lock is held from here: midnight, competing actions and amendments are strictly ordered.
  perform public.tt_clock_apply(r.code);
  select * into r from public.tt_rooms where code = r.code;
  s := r.state; before := s; ps := s->'players'; cfg := public.tt_rules(s); ver := public.tt_rules_version(s);
  is_host := r.host = auth.uid(); is_test := coalesce((s->>'isTest')::boolean, false);
  forfeit := (cfg->>'forfeitOnElimination')::boolean;
  select (ord-1)::int, value into idx, actor from jsonb_array_elements(ps) with ordinality a(value, ord) where value->>'uid' = auth.uid()::text;

  if p_action = 'start' then
    if not is_host then raise exception 'Host only'; end if;
    if s->>'phase' <> 'lobby' then raise exception 'Already started'; end if;
    n := jsonb_array_length(ps);
    if n < 5 then raise exception 'At least five players required'; end if;
    if n > 20 then raise exception 'At most twenty players'; end if;
    if (cfg->>'fixedBoard')::boolean then
      need := public.tt_board_size(ver, n);
      if need is null then raise exception 'This room''s rules version does not define a board for % players. Add or remove a player, or migrate the lobby to the current rules', n; end if;
      if p_size is not null and p_size <> need then raise exception 'These rules require a % by % board for % players', need, need, n; end if;
      side := need;
    else side := coalesce(p_size, n - 1);
    end if;
    if side < 3 or side > 24 or side * side < n then raise exception 'Invalid board size'; end if;
    select array_agg(x order by random()) into cells from generate_series(0, side*side - 1) x;
    for i in 0..n-1 loop
      cell := cells[i+1];
      item := (ps->i) || jsonb_build_object('x', cell % side, 'y', cell / side, 'movesToday', 0,
        'points', case when is_test then greatest((cfg->>'dailyIncome')::int, (ps->i->>'points')::int) else 0 end);
      ps := jsonb_set(ps, array[i::text], item);
    end loop;
    if is_test then
      s := s || jsonb_build_object('phase','active','size',side);
      public_event := 'Test game started. Opening income awarded.';
    else
      -- No spendable point exists before the opening; income arrives with the first midnight.
      due := (clock_timestamp() at time zone 'America/Los_Angeles')::date + 1;
      s := s || jsonb_build_object('phase','scheduled','size',side,'closed',true,'day',1,'nextReset',due::text);
      public_event := 'Game scheduled for ' || due::text || ' at 12:00 am Pacific.';
    end if;
  elsif p_action in ('next_day','close') then
    if not is_host then raise exception 'Host only'; end if;
    if not is_test then raise exception 'Normal rooms use the automatic Pacific schedule. Manual controls are for test rooms only'; end if;
    if s->>'phase' <> 'active' then raise exception 'No active game'; end if;
    if p_action = 'close' then s := jsonb_set(s, '{closed}', 'true'); public_event := 'The host closed actions for today.';
    else
      s := public.tt_rollover(s || jsonb_build_object('players', ps), false);
      update public.tt_amendments set status = 'applied' where room = r.code and status = 'scheduled'
        and id in (select (value #>> '{}')::uuid from jsonb_array_elements(s->'_applied'));
      s := (s - '_applied' - '_bonus') || jsonb_build_object('closed', false); ps := s->'players';
      detail := 'Host advanced the test day.';
    end if;
  else
    if s->>'phase' <> 'active' then raise exception 'No active game'; end if;
    if actor is null then raise exception 'The host referees; only players can act'; end if;
    if p_target is not null then
      select (ord-1)::int, value into tidx, target from jsonb_array_elements(ps) with ordinality a(value, ord) where (value->>'id')::int = p_target;
    end if;
    if p_action = 'vote' then
      if (actor->>'alive')::boolean then raise exception 'Only eliminated players may vote'; end if;
      if target is null or not (target->>'alive')::boolean then raise exception 'Choose a living recipient'; end if;
      s := jsonb_set(s, array['votes', actor->>'id'], to_jsonb(p_target)); detail := (actor->>'name') || ' cast a ballot.';
    else
      if (s->>'closed')::boolean then raise exception 'Actions are closed'; end if;
      if not (actor->>'alive')::boolean then raise exception 'You have been eliminated'; end if;
      cost := case p_action when 'move' then (cfg->>'costMove')::int when 'attack' then (cfg->>'costAttack')::int when 'give' then 1
        when 'shield' then (cfg->>'costShield')::int when 'range' then (cfg->>'costRange')::int when 'remove' then 0 else null end;
      if cost is null then raise exception 'Unknown action'; end if;
      if p_action <> 'remove' and not (cfg->>('allow' || initcap(p_action)))::boolean then
        raise exception 'That action is disabled by a rule amendment. No points spent';
      end if;
      if (actor->>'points')::int < cost then raise exception 'Not enough points'; end if;
      cap := (cfg->>'maxRange')::int;
      if p_action in ('attack','give') then
        if target is null or p_target = (actor->>'id')::int or not (target->>'alive')::boolean then raise exception 'Choose another living player'; end if;
        reach := case when cap > 0 then least((actor->>'range')::int, cap) else (actor->>'range')::int end;
        if abs((actor->>'x')::int - (target->>'x')::int) + abs((actor->>'y')::int - (target->>'y')::int) > reach then
          raise exception 'Target out of range';
        end if;
        if p_action = 'give' then
          target := target || jsonb_build_object('points', (target->>'points')::int + 1);
          if not is_test and not coalesce((target->>'isTestSeat')::boolean, false) then
            perform public.tt_notify(r.code, p_target, 'bonus', 'give:' || p_request::text);
          end if;
        else
          if (target->>'shield')::boolean then raise exception 'Target shielded; no points spent'; end if;
          target := target || jsonb_build_object('hearts', (target->>'hearts')::int - 1);
          if (target->>'hearts')::int <= 0 then
            target := target || jsonb_build_object('hearts', 0, 'alive', false, 'shield', false, 'shieldDays', 0);
            if forfeit then target := jsonb_set(target, '{points}', '0'::jsonb); end if;
            public_event := (actor->>'name') || ' eliminated ' || (target->>'name') || '.';
          end if;
        end if;
        ps := jsonb_set(ps, array[tidx::text], target);
      elsif p_action = 'move' then
        lim := (cfg->>'moveLimit')::int;
        if lim > 0 and coalesce((actor->>'movesToday')::int, 0) >= lim then raise exception 'Daily movement limit reached. No points spent'; end if;
        dx := case p_direction when 'left' then -1 when 'right' then 1 when 'up' then 0 when 'down' then 0 else null end;
        dy := case p_direction when 'up' then -1 when 'down' then 1 else 0 end;
        if dx is null then raise exception 'Choose a direction'; end if;
        newx := (actor->>'x')::int + dx; newy := (actor->>'y')::int + dy; side := (s->>'size')::int;
        if newx < 0 or newy < 0 or newx >= side or newy >= side or exists(select 1 from jsonb_array_elements(ps)
             where (value->>'alive')::boolean and (value->>'x')::int = newx and (value->>'y')::int = newy) then
          raise exception 'Tile blocked';
        end if;
        actor := actor || jsonb_build_object('x', newx, 'y', newy, 'movesToday', coalesce((actor->>'movesToday')::int, 0) + 1);
        public_event := (actor->>'name') || ' moved to ' || public.tt_square(s, newx, newy) || '.';
        if not is_test then perform public.tt_notify_room(r.code, s, 'movement', 'move:' || p_request::text, true, false, (actor->>'id')::int); end if;
      elsif p_action = 'shield' then
        if (actor->>'shield')::boolean then raise exception 'Already shielded'; end if;
        actor := actor || jsonb_build_object('shield', true, 'shieldDays', (cfg->>'shieldDays')::int);
      elsif p_action = 'range' then
        if cap > 0 and (actor->>'range')::int >= cap then raise exception 'Range is at the current cap. No points spent'; end if;
        actor := actor || jsonb_build_object('range', (actor->>'range')::int + 1);
      elsif p_action = 'remove' then
        actor := actor || jsonb_build_object('alive', false, 'shield', false, 'shieldDays', 0);
        public_event := (actor->>'name') || ' withdrew.';
      end if;
      actor := actor || jsonb_build_object('points', case when forfeit and not (actor->>'alive')::boolean then 0 else (actor->>'points')::int - cost end);
      ps := jsonb_set(ps, array[idx::text], actor);
      detail := (actor->>'name') || ': ' || p_action || case when target is not null then ' → ' || (target->>'name') else coalesce(' ' || p_direction, '') end;
    end if;
  end if;
  s := jsonb_set(s, '{players}', ps);
  if public_event is not null then s := jsonb_set(s, '{events}', jsonb_build_array(public_event) || (s->'events')); end if;
  s := jsonb_set(s, '{hostLog}', jsonb_build_array(to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS')
       || ' UTC · ' || coalesce(detail, public_event, 'Host action')) || (s->'hostLog'));
  perform public.tt_commit(r.code, before, s);
  insert into public.tt_requests values (r.code, auth.uid(), p_request);
  return public.tt_view(r.code);
end;$$;

-- ---------- Amendments ----------
-- Caller must hold the room lock, have run the clock, and have authorized the host.
create or replace function public.tt_amend_apply(p_code text, p_title text, p_reason text, p_effects jsonb,
  p_proposal uuid default null, p_corrects uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare s jsonb; before jsonb; res jsonb; q public.tt_proposals%rowtype; ps jsonb; actor jsonb; idx int; cost int; cfg jsonb;
  new_id uuid := gen_random_uuid(); summary text; who text; attribute boolean; has_later boolean;
begin
  select state into s from public.tt_rooms where code = p_code; before := s; cfg := public.tt_rules(s);
  attribute := (cfg->>'attributeProposals')::boolean;
  if length(trim(coalesce(p_title,''))) not between 1 and 80 then raise exception 'Give the amendment a title of 1–80 characters'; end if;
  if length(trim(coalesce(p_reason,''))) not between 1 and 500 then raise exception 'Add a public reason of 1–500 characters'; end if;
  if p_corrects is not null and not exists(select 1 from public.tt_amendments where id = p_corrects and room = p_code) then
    raise exception 'The amendment being corrected was not found in this room';
  end if;
  if p_proposal is not null then
    -- Payment and effects share this transaction: either both happen or neither does.
    select * into q from public.tt_proposals where id = p_proposal and room = p_code for update;
    if not found then raise exception 'Proposal unavailable'; end if;
    if q.status <> 'pending' then raise exception 'This proposal was already reviewed'; end if;
    if s->>'phase' <> 'active' or (s->>'closed')::boolean then raise exception 'Approval and payment require an open action window'; end if;
    ps := s->'players'; cost := (cfg->>'costProposal')::int;
    select (ord-1)::int, value into idx, actor from jsonb_array_elements(ps) with ordinality a(value, ord) where value->>'uid' = q.author::text;
    if actor is null or not (actor->>'alive')::boolean then raise exception 'Proposer is no longer alive; reject this proposal instead'; end if;
    if (actor->>'points')::int < cost then raise exception 'Proposer needs % points. No charge or approval was made', cost; end if;
    who := actor->>'name';
    s := jsonb_set(s, array['players', idx::text, 'points'], to_jsonb((actor->>'points')::int - cost));
  end if;
  res := public.tt_amend_eval(s, p_effects);
  if jsonb_array_length(res->'errors') > 0 then raise exception '%', res->'errors'->>0; end if;
  s := res->'state'; has_later := jsonb_array_length(res->'later') > 0;
  if has_later then
    if jsonb_array_length(coalesce(s->'pending','[]'::jsonb)) >= 10 then raise exception 'Ten scheduled amendments are already waiting. Cancel one first'; end if;
    s := jsonb_set(s, '{pending}', coalesce(s->'pending','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'id', new_id, 'applyAt', coalesce((s->>'rollovers')::int, 0) + 1, 'title', trim(p_title), 'effects', res->'later')));
  end if;
  insert into public.tt_amendments(id, room, origin, proposal, proposer_name, title, reason, effects, lines, undo, status, corrects)
  values (new_id, p_code, case when p_proposal is null then 'host' else 'proposal' end, p_proposal, who, trim(p_title), trim(p_reason),
    p_effects, res->'lines', jsonb_build_object('effects', res->'undo', 'caveats', res->'caveats'),
    case when has_later then 'scheduled' else 'applied' end, p_corrects);
  select string_agg(case when value->>'when' = 'next_reset' then 'From the next midnight reset: ' else '' end || (value->>'text'), ' ')
    into summary from jsonb_array_elements(res->'lines');
  s := jsonb_set(s, '{events}', jsonb_build_array(
    case when p_proposal is null then case when p_corrects is null then 'Rule amendment by the host: ' else 'Correction by the host: ' end || trim(p_title)
         else 'Host approved a rule change: ' || trim(p_title) || case when attribute then ' (proposed by ' || who || ')' else '' end end
    || ' — ' || summary || case when p_proposal is null then ' Reason: ' || trim(p_reason) else '' end) || (s->'events'));
  s := jsonb_set(s, '{hostLog}', jsonb_build_array(clock_timestamp()::text || ' · Amendment "' || trim(p_title) || '" recorded'
    || case when p_proposal is not null then '; charged ' || who || ' ' || cost || ' points.' else '.' end) || (s->'hostLog'));
  if p_proposal is not null then
    update public.tt_proposals set status = 'approved', reason = left(trim(p_reason), 300), reviewed_at = clock_timestamp() where id = q.id;
    perform public.tt_notify(p_code, (actor->>'id')::int, 'review', 'review:' || q.id::text);
  end if;
  perform public.tt_commit(p_code, before, s);
  perform public.tt_notify_room(p_code, s, 'rules', 'rules:' || new_id::text, false);
  return new_id;
end;$$;

-- Host-only dry run. Changes nothing. Shows exactly what tt_amend would do right now.
create or replace function public.tt_amend_preview(p_code text, p_effects jsonb, p_proposal uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; res jsonb; fin jsonb; sim jsonb; warnings jsonb; errors jsonb; q public.tt_proposals%rowtype; actor jsonb; cost int;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  if r.host <> auth.uid() then raise exception 'Host only'; end if;
  perform public.tt_clock_apply(r.code); select state into s from public.tt_rooms where code = r.code;
  if p_effects is null or jsonb_typeof(p_effects) <> 'array' then p_effects := '[]'::jsonb; end if;
  res := public.tt_amend_eval(s, p_effects); warnings := res->'warnings'; errors := res->'errors';
  if p_proposal is not null then
    select * into q from public.tt_proposals where id = p_proposal and room = r.code;
    cost := (public.tt_rules(s)->>'costProposal')::int;
    select value into actor from jsonb_array_elements(s->'players') where value->>'uid' = q.author::text;
    if q.id is null or q.status <> 'pending' then errors := errors || jsonb_build_array('This proposal is no longer pending');
    elsif s->>'phase' <> 'active' or (s->>'closed')::boolean then errors := errors || jsonb_build_array('Approval and payment require an open action window');
    elsif actor is null or not (actor->>'alive')::boolean then errors := errors || jsonb_build_array('Proposer is no longer alive; reject this proposal instead');
    elsif (actor->>'points')::int < cost then errors := errors || jsonb_build_array('Proposer does not currently have the ' || cost || ' points required');
    end if;
  end if;
  fin := public.tt_finish_state(res->'state');
  if jsonb_array_length(res->'later') > 0 and s->>'phase' in ('active','scheduled') then
    sim := public.tt_amend_eval((res->'state') || jsonb_build_object('phase','active'), res->'later', true);
    if public.tt_finish_state(sim->'state')->>'phase' = 'ended' and fin->>'phase' <> 'ended' then
      warnings := warnings || jsonb_build_array('If nothing else changes first, the scheduled part would end the match when it takes effect.');
    end if;
  end if;
  if coalesce((s->>'isTest')::boolean, false) and exists(select 1 from jsonb_array_elements(p_effects) where value->>'key' = 'cutoffHour') then
    warnings := warnings || jsonb_build_array('Test rooms use manual day controls; the cutoff hour has no effect here.');
  end if;
  return jsonb_build_object('ok', jsonb_array_length(errors) = 0, 'errors', errors, 'warnings', warnings, 'lines', res->'lines',
    'affects', case when exists(select 1 from jsonb_array_elements(p_effects) where jsonb_typeof(value->'target') = 'number') then 'One or more named players, plus everyone bound by the changed settings.' else 'Everyone in this room.' end,
    'changesExisting', exists(select 1 from jsonb_array_elements(p_effects) where value->>'type' in ('adjust','expire_shields') or value->>'key' in ('baseRange','startHearts')),
    'endsMatchNow', fin->>'phase' = 'ended' and s->>'phase' <> 'ended',
    'eliminates', (select count(*) from jsonb_array_elements(res->'state'->'players') a where not (a->>'alive')::boolean
       and exists(select 1 from jsonb_array_elements(s->'players') b where b->>'id' = a->>'id' and (b->>'alive')::boolean)),
    'proposalCost', cost, 'caveats', res->'caveats');
end;$$;

-- Host-originated amendment, or (with p_proposal) approval of a player proposal with composed effects.
create or replace function public.tt_amend(p_code text, p_request uuid, p_title text, p_reason text, p_effects jsonb,
  p_proposal uuid default null, p_corrects uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;
begin
  if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  if r.host <> auth.uid() then raise exception 'Host only'; end if;
  if exists(select 1 from public.tt_requests where room = r.code and user_id = auth.uid() and request_id = p_request) then return public.tt_view(r.code); end if;
  perform public.tt_clock_apply(r.code);
  perform public.tt_amend_apply(r.code, p_title, p_reason, p_effects, p_proposal, p_corrects);
  insert into public.tt_requests values (r.code, auth.uid(), p_request);
  return public.tt_view(r.code);
end;$$;

-- Cancels the not-yet-effective part of a scheduled amendment. Anything already applied stays applied.
create or replace function public.tt_amend_cancel(p_code text, p_request uuid, p_amendment uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; m public.tt_amendments%rowtype;
begin
  if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  if r.host <> auth.uid() then raise exception 'Host only'; end if;
  if exists(select 1 from public.tt_requests where room = r.code and user_id = auth.uid() and request_id = p_request) then return public.tt_view(r.code); end if;
  if length(trim(coalesce(p_reason,''))) not between 1 and 500 then raise exception 'Add a public reason of 1–500 characters'; end if;
  perform public.tt_clock_apply(r.code); select state into s from public.tt_rooms where code = r.code;
  select * into m from public.tt_amendments where id = p_amendment and room = r.code for update;
  if not found or m.status <> 'scheduled' then raise exception 'Only an amendment that is still scheduled can be cancelled'; end if;
  s := jsonb_set(s, '{pending}', (select coalesce(jsonb_agg(value), '[]'::jsonb) from jsonb_array_elements(s->'pending') where value->>'id' <> m.id::text));
  s := jsonb_set(s, '{events}', jsonb_build_array('The host cancelled the scheduled part of "' || m.title || '". Reason: ' || trim(p_reason)) || (s->'events'));
  update public.tt_amendments set status = 'cancelled' where id = m.id;
  update public.tt_rooms set state = s where code = r.code;
  insert into public.tt_requests values (r.code, auth.uid(), p_request);
  return public.tt_view(r.code);
end;$$;

-- Host-only: a suggested forward correction for an earlier amendment. Nothing is applied here.
create or replace function public.tt_amend_correction(p_code text, p_amendment uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare m public.tt_amendments%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if not exists(select 1 from public.tt_rooms where code = upper(trim(p_code)) and host = auth.uid()) then raise exception 'Host only'; end if;
  select * into m from public.tt_amendments where id = p_amendment and room = upper(trim(p_code));
  if not found then raise exception 'Amendment unavailable'; end if;
  return jsonb_build_object('id', m.id, 'title', left('Correction: ' || m.title, 80), 'effects', m.undo->'effects',
    'caveats', (m.undo->'caveats') || jsonb_build_array('A correction is a new public amendment. It does not erase history, refund actions players already took, or undo consequences that followed.'));
end;$$;

-- Deliberate, host-confirmed change of rules version. Never raises any player's range or resources
-- in a scheduled/running game; lobby seats take the new version's starting values.
create or replace function public.tt_migrate_rules(p_code text, p_request uuid, p_version text, p_confirm text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; ps jsonb; cfg jsonb; i int; old_ver text;
begin
  if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  if r.host <> auth.uid() then raise exception 'Host only'; end if;
  if exists(select 1 from public.tt_requests where room = r.code and user_id = auth.uid() and request_id = p_request) then return public.tt_view(r.code); end if;
  if coalesce(p_confirm,'') <> 'MIGRATE' then raise exception 'Type MIGRATE to confirm changing this room''s rules version'; end if;
  perform public.tt_clock_apply(r.code); select state into s from public.tt_rooms where code = r.code;
  old_ver := public.tt_rules_version(s);
  if s->>'phase' = 'ended' then raise exception 'This match is complete'; end if;
  if p_version is distinct from 'owner-2026-11' then raise exception 'Rooms can only be migrated to the current rules version'; end if;
  if old_ver = p_version then raise exception 'This room already uses that rules version'; end if;
  s := jsonb_set(s, '{rulesVersion}', to_jsonb(p_version)); cfg := public.tt_rules(s);
  if s->>'phase' = 'lobby' then
    ps := s->'players';
    for i in 0..jsonb_array_length(ps)-1 loop
      ps := jsonb_set(ps, array[i::text], (ps->i) || jsonb_build_object('range', (cfg->>'baseRange')::int,
        'hearts', (cfg->>'startHearts')::int, 'points', (cfg->>'lobbyPoints')::int));
    end loop;
    s := jsonb_set(s, '{players}', ps);
  end if;
  s := jsonb_set(s, '{events}', jsonb_build_array('The host migrated this room from rules ' || old_ver || ' to ' || p_version || '. '
    || case when s->>'phase' = 'lobby' then 'Lobby seats now use the new starting values.'
            else 'Costs, cutoff and elimination rules now follow the new version. No player''s current range, hearts or points were changed.' end) || (s->'events'));
  s := jsonb_set(s, '{hostLog}', jsonb_build_array(clock_timestamp()::text || ' · Rules version migrated ' || old_ver || ' → ' || p_version || '.') || (s->'hostLog'));
  update public.tt_rooms set state = s where code = r.code;
  insert into public.tt_requests values (r.code, auth.uid(), p_request);
  return public.tt_view(r.code);
end;$$;

-- ---------- Player proposals ----------
create or replace function public.tt_propose(p_code text, p_request uuid, p_title text, p_body text, p_kind text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; actor jsonb; s jsonb; cost int;
begin
  if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  select value into actor from jsonb_array_elements(r.state->'players') where value->>'uid' = auth.uid()::text;
  if actor is null then raise exception 'Only a player can propose a change'; end if;
  if exists(select 1 from public.tt_requests where room = r.code and user_id = auth.uid() and request_id = p_request) then return public.tt_view(r.code); end if;
  perform public.tt_clock_apply(r.code); select state into s from public.tt_rooms where code = r.code; cost := (public.tt_rules(s)->>'costProposal')::int;
  select value into actor from jsonb_array_elements(s->'players') where value->>'uid' = auth.uid()::text;
  if s->>'phase' <> 'active' or (s->>'closed')::boolean then raise exception 'Proposals require an active, open action window'; end if;
  if not (actor->>'alive')::boolean then raise exception 'Eliminated players cannot propose changes'; end if;
  if (actor->>'points')::int < cost then raise exception 'You need % available points to propose; charged only on approval', cost; end if;
  if exists(select 1 from public.tt_proposals where room = r.code and author = auth.uid() and status = 'pending') then raise exception 'You already have a pending proposal'; end if;
  if p_kind is null or p_kind not in ('house_rule','all_hearts') then raise exception 'Unsupported rule type'; end if;
  if p_title is null or length(trim(p_title)) not between 1 and 80 or p_body is null or length(trim(p_body)) not between 1 and 1000 then
    raise exception 'Add a title (1–80 characters) and details (1–1000 characters)';
  end if;
  insert into public.tt_proposals(room, author, title, body, kind) values (r.code, auth.uid(), trim(p_title), trim(p_body), p_kind);
  insert into public.tt_requests values (r.code, auth.uid(), p_request);
  if not coalesce((s->>'isTest')::boolean, false) then perform public.tt_notify(r.code, -1, 'review', 'proposal:' || p_request::text); end if;
  return public.tt_view(r.code);
end;$$;

create or replace function public.tt_propose_survivors(p_code text, p_request uuid, p_title text, p_body text, p_count int) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; actor jsonb; s jsonb; cost int;
begin
  if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  select value into actor from jsonb_array_elements(r.state->'players') where value->>'uid' = auth.uid()::text;
  if actor is null then raise exception 'Only a player can propose a change'; end if;
  if exists(select 1 from public.tt_requests where room = r.code and user_id = auth.uid() and request_id = p_request) then return public.tt_view(r.code); end if;
  perform public.tt_clock_apply(r.code); select state into s from public.tt_rooms where code = r.code; cost := (public.tt_rules(s)->>'costProposal')::int;
  select value into actor from jsonb_array_elements(s->'players') where value->>'uid' = auth.uid()::text;
  if s->>'phase' <> 'active' or (s->>'closed')::boolean then raise exception 'Proposals require an active, open action window'; end if;
  if not (actor->>'alive')::boolean then raise exception 'Eliminated players cannot propose changes'; end if;
  if (actor->>'points')::int < cost then raise exception 'You need % available points to propose; charged only on approval', cost; end if;
  if exists(select 1 from public.tt_proposals where room = r.code and author = auth.uid() and status = 'pending') then raise exception 'You already have a pending proposal'; end if;
  if p_count is null or p_count < 1 or p_count > jsonb_array_length(s->'players') or p_count > 20 then raise exception 'Choose a survivor target between 1 and the initial player count'; end if;
  if p_count = coalesce((s->>'survivorGoal')::int, 1) then raise exception 'That survivor target is already active'; end if;
  if p_title is null or length(trim(p_title)) not between 1 and 80 or p_body is null or length(trim(p_body)) not between 1 and 1000 then
    raise exception 'Add a title (1–80 characters) and details (1–1000 characters)';
  end if;
  insert into public.tt_proposals(room, author, title, body, kind, survivor_count) values (r.code, auth.uid(), trim(p_title), trim(p_body), 'last_survivors', p_count);
  insert into public.tt_requests values (r.code, auth.uid(), p_request);
  if not coalesce((s->>'isTest')::boolean, false) then perform public.tt_notify(r.code, -1, 'review', 'proposal:' || p_request::text); end if;
  return public.tt_view(r.code);
end;$$;

-- Reject, or quick-approve with the proposal's own built-in effect. Composed approvals use tt_amend.
create or replace function public.tt_review(p_code text, p_request uuid, p_proposal uuid, p_decision text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; q public.tt_proposals%rowtype; effects jsonb; seat int;
begin
  if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  if r.host <> auth.uid() then raise exception 'Host only'; end if;
  if exists(select 1 from public.tt_requests where room = r.code and user_id = auth.uid() and request_id = p_request) then return public.tt_view(r.code); end if;
  if p_decision is null or p_decision not in ('approve','reject') or length(coalesce(p_reason,'')) > 300 then
    raise exception 'Choose approve or reject; reason maximum 300 characters';
  end if;
  select * into q from public.tt_proposals where id = p_proposal and room = r.code for update;
  if not found then raise exception 'Proposal unavailable'; end if;
  if q.status <> 'pending' then raise exception 'This proposal was already reviewed'; end if;
  perform public.tt_clock_apply(r.code);
  if p_decision = 'approve' then
    effects := case q.kind
      when 'all_hearts' then jsonb_build_array(jsonb_build_object('type','adjust','resource','hearts','target','living','amount',1))
      when 'last_survivors' then jsonb_build_array(jsonb_build_object('type','set','key','survivorGoal','value',q.survivor_count))
      else jsonb_build_array(jsonb_build_object('type','written','text',left(q.body, 500))) end;
    perform public.tt_amend_apply(r.code, q.title, coalesce(nullif(trim(p_reason),''), 'Approved as proposed.'), effects, q.id, null);
  else
    update public.tt_proposals set status = 'rejected', reason = coalesce(p_reason,''), reviewed_at = clock_timestamp() where id = q.id;
    select (value->>'id')::int into seat from jsonb_array_elements(r.state->'players') where value->>'uid' = q.author::text;
    if seat is not null and not coalesce((r.state->>'isTest')::boolean, false) then perform public.tt_notify(r.code, seat, 'review', 'review:' || q.id::text); end if;
  end if;
  insert into public.tt_requests values (r.code, auth.uid(), p_request);
  return public.tt_view(r.code);
end;$$;

revoke all on function public.tt_rules_version(jsonb), public.tt_rules_profile(text), public.tt_rules(jsonb), public.tt_board_size(text,int),
  public.tt_proposal_cost(jsonb), public.tt_square(jsonb,int,int), public.tt_rules_catalog(), public.tt_finish_state(jsonb),
  public.tt_amend_eval(jsonb,jsonb,boolean), public.tt_rollover(jsonb,boolean), public.tt_commit(text,jsonb,jsonb),
  public.tt_clock_apply(text,timestamptz), public.tt_finish_if_ready(text), public.tt_view_core(text), public.tt_create(),
  public.tt_join(text,text), public.tt_set_room_name(text,text), public.tt_fill_test_seats(text),
  public.tt_command(text,uuid,text,int,text,int), public.tt_amend_apply(text,text,text,jsonb,uuid,uuid),
  public.tt_amend_preview(text,jsonb,uuid), public.tt_amend(text,uuid,text,text,jsonb,uuid,uuid),
  public.tt_amend_cancel(text,uuid,uuid,text), public.tt_amend_correction(text,uuid), public.tt_migrate_rules(text,uuid,text,text),
  public.tt_propose(text,uuid,text,text,text), public.tt_propose_survivors(text,uuid,text,text,int),
  public.tt_review(text,uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.tt_rules_catalog(), public.tt_create(), public.tt_join(text,text), public.tt_set_room_name(text,text),
  public.tt_fill_test_seats(text), public.tt_command(text,uuid,text,int,text,int), public.tt_amend_preview(text,jsonb,uuid),
  public.tt_amend(text,uuid,text,text,jsonb,uuid,uuid), public.tt_amend_cancel(text,uuid,uuid,text),
  public.tt_amend_correction(text,uuid), public.tt_migrate_rules(text,uuid,text,text), public.tt_propose(text,uuid,text,text,text),
  public.tt_propose_survivors(text,uuid,text,text,int), public.tt_review(text,uuid,uuid,text,text) to authenticated;
commit;
notify pgrst, 'reload schema';
