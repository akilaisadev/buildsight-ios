-- Run once in the Supabase SQL editor to drop "Demo" from the names the app shows.
-- Change the two quoted names below if you want something else.

-- Project name lives inside the payload; bump the version and time so every device pulls it.
update projects
set payload = jsonb_set(payload, '{name}', to_jsonb('BuildSight Site'::text)),
    updated_at = now(),
    server_version = server_version + 1
where payload->>'name' ilike '%demo%';

-- Organisation name (shown in Settings).
update organisations set name = 'BuildSight' where name ilike '%demo%';

-- Check: both queries should now return no rows.
select id, payload->>'name' as name from projects where payload->>'name' ilike '%demo%';
select id, name from organisations where name ilike '%demo%';
