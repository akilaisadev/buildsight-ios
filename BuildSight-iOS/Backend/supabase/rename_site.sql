-- Renames the project and organisation shown in the app. Already applied to the live project.
-- The project's name is stored in its `records` row (type 'project'), not in the `projects` table.
-- Before: project "BuildSight Demo Site", organisation "BuildSight Demo".

update records
set payload = jsonb_set(payload, '{name}', to_jsonb('BuildSight Site'::text)),
    updated_at = now(),
    server_version = server_version + 1
where type = 'project' and payload->>'name' = 'BuildSight Demo Site';

update organisations set name = 'BuildSight' where name = 'BuildSight Demo';

-- Check: names changed, and nothing says demo any more.
select payload->>'name' as project from records where type = 'project';
select name as organisation from organisations;
select count(*) as records_mentioning_demo from records where payload::text ilike '%demo%';
