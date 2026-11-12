-- Release upgrade 4 of 5. Run AFTER 022_rules_engine.sql. Safe to re-run. Existing messages are kept.
-- Adds quoted replies, direct-message notifications, finished-game retention (24 hours) and
-- host deletion of a finished room. Text and rate limits are unchanged (1000 chars, 1/s, 20/min).
begin;
alter table public.tt_chat_messages add column if not exists reply_to uuid references public.tt_chat_messages(id) on delete set null;

-- Retention clock: finished-game chat is readable for 24 hours after the match ended.
create or replace function public.tt_chat_expired(p_state jsonb) returns boolean
language sql stable set search_path='' as $$
  select p_state->>'phase' = 'ended' and p_state->>'endedAt' is not null
     and (p_state->>'endedAt')::timestamptz + interval '24 hours' <= clock_timestamp()
$$;

-- Locks the room through authorization/read/send/ack; recovery uses that same room lock.
create or replace function public.tt_chat_slot(p_code text) returns int
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; slot int;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room unavailable'; end if;
  if r.host = auth.uid() then slot := -1;
  else
    select (value->>'id')::int into slot from jsonb_array_elements(r.state->'players')
      where value->>'uid' = auth.uid()::text and not coalesce((value->>'isTestSeat')::boolean, false);
  end if;
  if slot is null then raise exception 'Room unavailable'; end if;
  -- Enforced on access, so content is unreadable even if the hourly purge has not run yet.
  if public.tt_chat_expired(r.state) then raise exception 'Chat for this finished game has expired'; end if;
  return slot;
end;$$;

drop function if exists public.tt_chat_send(text,uuid,text,int);
create or replace function public.tt_chat_send(p_code text, p_request uuid, p_body text, p_peer int default null, p_reply uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c text := upper(trim(p_code)); slot int; m public.tt_chat_messages%rowtype; body_text text := btrim(p_body, E' \t\n\r');
  who text; last_at timestamptz; recent int; q public.tt_chat_messages%rowtype; test_room boolean;
begin
  slot := public.tt_chat_slot(c); perform public.tt_chat_peer(c, slot, p_peer);
  if p_request is null then raise exception 'Message request ID required'; end if;
  if body_text is null or length(body_text) not between 1 and 1000 then raise exception 'Use 1 to 1000 characters'; end if;
  -- Seat-keyed deduplication survives role recovery. A request ID cannot be reused with different content.
  select * into m from public.tt_chat_messages where room = c and sender = slot and request_id = p_request;
  if found then
    if m.body <> body_text or m.recipient is distinct from p_peer then raise exception 'That request ID belongs to a different message'; end if;
  else
    if p_reply is not null then
      -- A quote must live in THIS conversation: same room, and the same channel or the same pair.
      select * into q from public.tt_chat_messages where id = p_reply and room = c
        and ((p_peer is null and recipient is null)
          or (p_peer is not null and ((sender = slot and recipient = p_peer) or (sender = p_peer and recipient = slot))));
      if not found then raise exception 'You can only reply to a message in this conversation'; end if;
    end if;
    select max(sent_at), count(*) filter (where sent_at > clock_timestamp() - interval '1 minute') into last_at, recent
      from public.tt_chat_messages where room = c and sender = slot;
    if last_at > clock_timestamp() - interval '1 second' then raise exception 'Please wait a second before sending another message'; end if;
    if recent >= 20 then raise exception 'Message limit reached. Wait a minute before sending again'; end if;
    if slot = -1 then who := 'Host / referee';
    else select a->>'name' into who from public.tt_rooms r cross join lateral jsonb_array_elements(r.state->'players') a where r.code = c and (a->>'id')::int = slot;
    end if;
    insert into public.tt_chat_messages(room, sender, recipient, sender_name, body, request_id, reply_to)
      values (c, slot, p_peer, who, body_text, p_request, p_reply) returning * into m;
    select coalesce((state->>'isTest')::boolean, false) into test_room from public.tt_rooms where code = c;
    if p_peer is not null and not test_room then perform public.tt_notify(c, p_peer, 'dm', 'dm:' || m.id::text); end if;
  end if;
  return jsonb_build_object('id',m.id,'sender',m.sender,'recipient',m.recipient,'senderName',m.sender_name,'body',m.body,'sentAt',m.sent_at,'replyTo',m.reply_to);
end;$$;

-- The quoted excerpt is read from the original at display time and never stored as a copy, so
-- deleting or expiring the original also removes every quote of it.
create or replace function public.tt_chat_list(p_code text, p_peer int default null, p_before uuid default null, p_after uuid default null, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c text := upper(trim(p_code)); slot int; cursor_seq bigint; lim int := least(100, greatest(1, coalesce(p_limit, 50)));
  items jsonb; more boolean; oldest uuid; newest uuid;
begin
  slot := public.tt_chat_slot(c); perform public.tt_chat_peer(c, slot, p_peer);
  if p_before is not null and p_after is not null then raise exception 'Choose one message cursor'; end if;
  if coalesce(p_before, p_after) is not null then
    select seq into cursor_seq from public.tt_chat_messages where id = coalesce(p_before, p_after) and room = c
      and ((p_peer is null and recipient is null) or (p_peer is not null and ((sender = slot and recipient = p_peer) or (sender = p_peer and recipient = slot))));
    if not found then raise exception 'Message cursor unavailable'; end if;
  end if;
  with candidates as (
    select * from public.tt_chat_messages where room = c
      and ((p_peer is null and recipient is null) or (p_peer is not null and ((sender = slot and recipient = p_peer) or (sender = p_peer and recipient = slot))))
      and (p_before is null or seq < cursor_seq) and (p_after is null or seq > cursor_seq)
    order by case when p_after is null then seq end desc, case when p_after is not null then seq end asc limit lim + 1
  ), page as (
    select * from candidates order by case when p_after is null then seq end desc, case when p_after is not null then seq end asc limit lim
  )
  select coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'sender',p.sender,'recipient',p.recipient,'senderName',p.sender_name,
            'body',p.body,'sentAt',p.sent_at,
            'reply', case when p.reply_to is null then null else (
              -- Re-checked on every read: the quote must still belong to this same conversation.
              select jsonb_build_object('id',o.id,'sender',o.sender,'senderName',o.sender_name,'excerpt',left(o.body, 140))
                from public.tt_chat_messages o where o.id = p.reply_to and o.room = c
                 and ((p.recipient is null and o.recipient is null)
                   or (p.recipient is not null and o.recipient is not null
                       and least(o.sender, o.recipient) = least(p.sender, p.recipient)
                       and greatest(o.sender, o.recipient) = greatest(p.sender, p.recipient)))) end)
            order by p.seq) from page p), '[]'::jsonb),
         (select count(*) > lim from candidates), (select id from page order by seq limit 1), (select id from page order by seq desc limit 1)
    into items, more, oldest, newest;
  -- Internal sequence numbers are never returned: other conversations' traffic is not an ID counter.
  return jsonb_build_object('messages', items, 'hasMore', more, 'oldestId', oldest, 'newestId', newest);
end;$$;

-- Hourly job target (see 024). Also callable by an administrator. Deletes content only:
-- rooms, results, proposals and accounts are untouched.
create or replace function public.tt_chat_purge() returns int
language plpgsql security definer set search_path='' as $$
declare n int;
begin
  delete from public.tt_chat_reads d using public.tt_rooms r where d.room = r.code and public.tt_chat_expired(r.state);
  delete from public.tt_chat_messages m using public.tt_rooms r where m.room = r.code and public.tt_chat_expired(r.state);
  get diagnostics n = row_count;
  return n;
end;$$;

-- Host deletes a FINISHED room: its chat, proposals, amendments, recovery codes and queued
-- notifications go with it. Accounts are untouched. Irreversible.
create or replace function public.tt_delete_room(p_code text, p_confirm text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into r from public.tt_rooms where code = upper(trim(p_code)) for update;
  -- A repeated request after success finds nothing and reports the same result.
  if not found then return jsonb_build_object('deleted', true); end if;
  if r.host <> auth.uid() then raise exception 'Host only'; end if;
  if r.state->>'phase' <> 'ended' then raise exception 'Only a finished game can be deleted'; end if;
  if coalesce(p_confirm,'') <> 'DELETE' then raise exception 'Type DELETE to confirm'; end if;
  delete from public.tt_chat_reads where room = r.code;
  delete from public.tt_chat_messages where room = r.code;
  delete from public.tt_amendments where room = r.code;
  delete from public.tt_proposals where room = r.code;
  delete from public.tt_recovery where room = r.code;
  delete from public.tt_requests where room = r.code;
  delete from public.tt_outbox where room = r.code;
  delete from public.tt_rooms where code = r.code;
  return jsonb_build_object('deleted', true);
end;$$;

revoke all on function public.tt_chat_expired(jsonb), public.tt_chat_slot(text), public.tt_chat_send(text,uuid,text,int,uuid),
  public.tt_chat_list(text,int,uuid,uuid,int), public.tt_chat_purge(), public.tt_delete_room(text,text) from public, anon, authenticated;
grant execute on function public.tt_chat_send(text,uuid,text,int,uuid), public.tt_chat_list(text,int,uuid,uuid,int),
  public.tt_delete_room(text,text) to authenticated;
grant execute on function public.tt_chat_purge() to service_role;
commit;
notify pgrst, 'reload schema';
