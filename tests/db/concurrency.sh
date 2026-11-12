#!/bin/sh
# Real concurrent sessions against the local database "tt" (built by release.sh).
# Each scenario fires competing requests from separate connections at the same instant and
# then checks the stored outcome. Leaves its fixture room in the throwaway database.
export PGHOST=127.0.0.1 PGPORT=${TT_PG_PORT:-54329} PGUSER=postgres PGDATABASE=tt
H=00000000-0000-4000-8000-0000000000f0; A=00000000-0000-4000-8000-0000000000a0
B=00000000-0000-4000-8000-0000000000b0; C=00000000-0000-4000-8000-0000000000c0
OUT=$(mktemp -d); fail=0
as() { psql -Atq -c "select set_config('request.jwt.claim.sub','$1',false); $2" >"$OUT/$3" 2>&1 & }
q() { psql -Atq -c "$1"; }
check() { if [ "$(q "$2")" = t ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
place() { q "update tt_rooms set state = jsonb_set(state, '{players,$1}', (state->'players'->$1) || '$2'::jsonb) where code = '$ROOM'" >/dev/null; }

q "delete from auth.users where id in ('$H','$A','$B','$C')" >/dev/null 2>&1
for u in "$H hostc" "$A anna" "$B bert" "$C cara"; do set -- $u
  q "insert into auth.users(id,email) values ('$1','$2@c.invalid'); select set_config('request.jwt.claim.sub','$1',false); select public.tt_profile_save('$2','$2');" >/dev/null
done
ROOM=$(q "select set_config('request.jwt.claim.sub','$H',false); select public.tt_create()->>'code';" | tail -1)
for u in $A $B $C; do q "select set_config('request.jwt.claim.sub','$u',false); select public.tt_join('$ROOM');" >/dev/null; done
q "select set_config('request.jwt.claim.sub','$H',false); select public.tt_fill_test_seats('$ROOM'); select public.tt_command('$ROOM', gen_random_uuid(), 'start');" >/dev/null

# 1. Three players step onto the same empty square b8 (1,0).
place 0 '{"x":0,"y":0,"points":5}'; place 1 '{"x":2,"y":0,"points":5}'; place 2 '{"x":1,"y":1,"points":5}'; place 3 '{"x":7,"y":7}'; place 4 '{"x":7,"y":5}'
as $A "select public.tt_command('$ROOM', gen_random_uuid(), 'move', null, 'right')" m1
as $B "select public.tt_command('$ROOM', gen_random_uuid(), 'move', null, 'left')" m2
as $C "select public.tt_command('$ROOM', gen_random_uuid(), 'move', null, 'up')" m3
wait
check "competing moves: exactly one occupant, one charge, two 'Tile blocked'" "select (select count(*) from jsonb_array_elements(state->'players') p where p->>'x'='1' and p->>'y'='0') = 1
  and (select sum((p->>'points')::int) from jsonb_array_elements(state->'players') p where (p->>'id')::int < 3) = 14 from tt_rooms where code='$ROOM'"
[ "$(cat "$OUT"/m1 "$OUT"/m2 "$OUT"/m3 | grep -c 'Tile blocked')" = 2 ] || { echo "FAIL competing moves: wrong rejection reasons"; fail=1; }

# 2. Three final attacks on a one-heart target.
place 0 '{"x":0,"y":0,"points":5}'; place 1 '{"x":2,"y":0,"points":5}'; place 2 '{"x":1,"y":1,"points":5}'; place 3 '{"x":1,"y":0,"hearts":1}'
for n in 1 2 3; do eval "u=\$$(echo A B C | cut -d' ' -f$n)"; as "$u" "select public.tt_command('$ROOM', gen_random_uuid(), 'attack', 3)" "a$n"; done
wait
check "competing final attacks: one elimination, one announcement, one point spent" "select state->'players'->3->>'alive' = 'false'
  and (select count(*) from jsonb_array_elements_text(state->'events') e where e like '% eliminated %') = 1
  and (select sum((p->>'points')::int) from jsonb_array_elements(state->'players') p where (p->>'id')::int < 3) = 14 from tt_rooms where code='$ROOM'"
[ "$(cat "$OUT"/a1 "$OUT"/a2 "$OUT"/a3 | grep -c 'Choose another living player')" = 2 ] || { echo "FAIL final attacks: wrong rejection reasons"; fail=1; }

# 3. The same request ID delivered six times at once (retry storm).
place 0 '{"points":9,"range":4}'
R=$(q "select gen_random_uuid()")
for n in 1 2 3 4 5 6; do as $A "select public.tt_command('$ROOM', '$R', 'range')" "r$n"; done
wait
check "duplicate request: applied and charged once" "select state->'players'->0->>'range' = '5' and state->'players'->0->>'points' = '7' from tt_rooms where code='$ROOM'"

# 4. Attack versus shield on the same target: either order is fine, a mixed outcome is not.
place 0 '{"x":0,"y":0,"points":5}'; place 1 '{"x":0,"y":1,"points":5,"hearts":3,"shield":false}'
as $A "select public.tt_command('$ROOM', gen_random_uuid(), 'attack', 1)" s1
as $B "select public.tt_command('$ROOM', gen_random_uuid(), 'shield')" s2
wait
check "attack vs shield: hit-and-charged, or rejected-and-free" "select state->'players'->1->>'shield' = 'true' and state->'players'->1->>'points' = '3'
  and ((state->'players'->1->>'hearts' = '2' and state->'players'->0->>'points' = '4') or (state->'players'->1->>'hearts' = '3' and state->'players'->0->>'points' = '5')) from tt_rooms where code='$ROOM'"

# 5. Transfer and spending race on a one-point balance: no negative balance, no created points.
place 0 '{"x":0,"y":0,"points":1}'; place 1 '{"x":0,"y":1,"points":0,"shield":false}'; place 2 '{"x":1,"y":1,"points":0}'
as $A "select public.tt_command('$ROOM', gen_random_uuid(), 'give', 1)" g1
as $A "select public.tt_command('$ROOM', gen_random_uuid(), 'give', 2)" g2
as $A "select public.tt_command('$ROOM', gen_random_uuid(), 'move', null, 'right')" g3
wait
check "spending race: one point spent exactly once, never negative" "select state->'players'->0->>'points' = '0'
  and (select sum((p->>'points')::int) from jsonb_array_elements(state->'players') p where (p->>'id')::int < 3) <= 1 from tt_rooms where code='$ROOM'"

# 6. Concurrent amendments: five distinct ones all apply in order; five copies of one apply once.
place 0 '{"points":0}'
for n in 1 2 3 4 5; do as $H "select public.tt_amend('$ROOM', gen_random_uuid(), 'Grant $n', 'Concurrency check', '[{\"type\":\"adjust\",\"resource\":\"points\",\"target\":0,\"amount\":1}]'::jsonb)" "d$n"; done
wait
R=$(q "select gen_random_uuid()")
for n in 1 2 3 4 5; do as $H "select public.tt_amend('$ROOM', '$R', 'Same grant', 'Concurrency check', '[{\"type\":\"adjust\",\"resource\":\"points\",\"target\":0,\"amount\":1}]'::jsonb)" "e$n"; done
wait
check "concurrent amendments: 5 distinct applied, 5 duplicates applied once" "select state->'players'->0->>'points' = '6'
  and (select count(*) from tt_amendments where room='$ROOM') = 6 from tt_rooms where code='$ROOM'"

# 7. Background clock job racing player requests never deadlocks or double-pays (normal room, due reset).
q "update tt_rooms set state = state - 'isTest' || jsonb_build_object('nextReset', ((now() at time zone 'America/Los_Angeles')::date)::text, 'rules', '{\"cutoffHour\":24}'::jsonb) where code='$ROOM'" >/dev/null
BEFORE=$(q "select state->'players'->1->>'points' from tt_rooms where code='$ROOM'")
for n in 1 2 3; do psql -Atq -c "select public.tt_clock_all()" >"$OUT/c$n" 2>&1 & done
as $A "select public.tt_view('$ROOM')" v1; as $B "select public.tt_view('$ROOM')" v2
wait
check "midnight job vs requests: income exactly once" "select (state->'players'->1->>'points')::int = $BEFORE + 1 from tt_rooms where code='$ROOM'"
grep -l "deadlock\|ERROR" "$OUT"/c? "$OUT"/v? >/dev/null 2>&1 && { echo "FAIL midnight job raised an error"; fail=1; }

rm -rf "$OUT"; exit $fail
