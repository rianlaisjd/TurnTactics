-- Release upgrade 5 of 5. Run AFTER 023, as the project admin, in the SQL Editor.
-- NOT transactional fixtures: this schedules background jobs. Re-running updates the same job names.
-- Prerequisites: pg_cron (already enabled by 008) and pg_net (Database → Extensions).
--
-- BEFORE running the push job section, store two Vault secrets ONCE (values are yours; never commit them):
--   select vault.create_secret('https://<your-project-ref>.supabase.co', 'tt_project_url');
--   select vault.create_secret('<the same random value you set as the TT_CRON_SECRET function secret>', 'tt_cron_secret');

-- 1. Finished-game chat: delete content 24 hours after a match ended. Hourly; access is also
--    refused by the chat functions the moment the 24 hours pass, so a late job leaks nothing.
create extension if not exists pg_cron;
select cron.schedule('turn-tactics-chat-purge', '7 * * * *', 'select public.tt_chat_purge();');

-- 2. Push delivery: once a minute, ask the tt-push Edge Function to claim and send queued events.
--    Quiet hours, preferences and seat ownership are enforced inside tt_push_claim, not here.
create extension if not exists pg_net;
select cron.schedule('turn-tactics-push', '* * * * *', $job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'tt_project_url') || '/functions/v1/tt-push',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-tt-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'tt_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 20000) as request_id;
$job$);

-- 3. Keep this project's job history for 7 days (extends the cleanup created by 008).
select cron.schedule('turn-tactics-clock-log-cleanup', '17 10 * * *', $job$
  delete from cron.job_run_details where jobid in (select jobid from cron.job where jobname like 'turn-tactics-%')
    and end_time < now() - interval '7 days';
$job$);

-- Confirm: four active jobs.
select jobname, schedule, active from cron.job where jobname like 'turn-tactics-%' order by jobname;
-- To pause push delivery without losing queued events:  select cron.unschedule('turn-tactics-push');
