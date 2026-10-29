-- BuildSight backend schema (PostgreSQL on Supabase).
--
-- Design: every synced record is one row in `records`, mirroring the app's
-- Core Data layout (type + project + parent + JSON payload). Row-level
-- security is the server-side authorisation the proposal requires: a user can
-- only read or write rows of projects they are a member of, whatever the client
-- sends. Role checks for sensitive transitions are enforced in the trigger.
--
-- Behaviour of upsert_record and the policies is covered by test_schema.sh, which
-- runs this file on a local PostgreSQL with stand-ins for Supabase's auth/storage
-- schemas. It was applied to the project's database, but its behaviour has not been
-- exercised live (no users yet): run scripts/backend-smoke.sh. See docs/BACKEND_SETUP.md.

create extension if not exists pgcrypto;

create type app_role as enum ('siteWorker','engineer','supervisor','inspector','projectManager');

create table organisations (
  id uuid primary key default gen_random_uuid(),
  name text not null
);

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  organisation_id uuid references organisations(id)
);

create table projects (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisations(id),
  payload jsonb not null,                 -- Project as the app decodes it
  updated_at timestamptz not null default now(),
  server_version int not null default 1
);

create table memberships (
  project_id uuid not null references projects(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role app_role not null,
  primary key (project_id, user_id)
);

create table records (
  id uuid primary key,                    -- client-generated: retried creates upsert, never duplicate
  type text not null,
  project_id uuid not null references projects(id) on delete cascade,
  parent_id uuid,
  sort_date timestamptz not null,
  payload jsonb not null,
  object_path text,                       -- evidence file in Storage, for photos
  created_by uuid not null default auth.uid(),
  updated_at timestamptz not null default now(),
  server_version int not null default 1,
  last_operation uuid                     -- idempotency key of the last applied operation
);
create index records_project_type on records (project_id, type, sort_date desc);
create index records_project_updated on records (project_id, updated_at);
create index records_parent on records (type, parent_id);

-- Membership helper used by every policy.
create function is_member(p uuid) returns boolean
  language sql stable security definer set search_path = public as
  $$ select exists (select 1 from memberships m where m.project_id = p and m.user_id = auth.uid()) $$;

create function role_in(p uuid) returns app_role
  language sql stable security definer set search_path = public as
  $$ select role from memberships m where m.project_id = p and m.user_id = auth.uid() $$;

alter table organisations enable row level security;
alter table profiles enable row level security;
alter table projects enable row level security;
alter table memberships enable row level security;
alter table records enable row level security;

create policy profile_self on profiles for select using (id = auth.uid() or exists (
  select 1 from memberships a join memberships b on a.project_id = b.project_id
  where a.user_id = auth.uid() and b.user_id = profiles.id));
create policy org_read on organisations for select using (exists (
  select 1 from profiles p where p.id = auth.uid() and p.organisation_id = organisations.id));
create policy project_read on projects for select using (is_member(id));
create policy membership_read on memberships for select using (is_member(project_id));

create policy records_read on records for select using (is_member(project_id));
-- Clients never write `records` directly: no insert/update/delete policies exist.
-- All writes go through upsert_record(), which is where authorisation,
-- idempotency and optimistic concurrency are enforced.
create function upsert_record(
  p_id uuid, p_type text, p_project uuid, p_parent uuid, p_sort_date timestamptz,
  p_payload jsonb, p_object_path text, p_base_version numeric, p_operation uuid
) returns int
language plpgsql security definer set search_path = public as $$
declare cur records%rowtype; r app_role := role_in(p_project);
begin
  if r is null then raise exception 'not_a_member' using errcode = 'P0403'; end if;

  -- Projects, areas and team members are reference data managed by an
  -- administrator (SQL editor / service role). Clients only read them.
  if p_type in ('project','siteArea','teamMember') then
    raise exception 'role_not_permitted' using errcode = 'P0403'; end if;

  select * into cur from records where id = p_id for update;
  if not found then
    -- New issues must start open: otherwise a worker could create one already
    -- verified or closed and skip the role checks below.
    if p_type = 'issue' and (p_payload->>'status') is distinct from 'open' then
      raise exception 'role_not_permitted' using errcode = 'P0403'; end if;
    insert into records (id, type, project_id, parent_id, sort_date, payload, object_path, created_by, last_operation)
    values (p_id, p_type, p_project, p_parent, p_sort_date, p_payload, p_object_path, auth.uid(), p_operation);
    return 1;
  end if;

  if cur.project_id <> p_project then raise exception 'not_a_member' using errcode = 'P0403'; end if;
  if cur.last_operation = p_operation then return cur.server_version; end if;   -- replay: already applied
  if cur.server_version <> p_base_version::int then raise exception 'version_conflict' using errcode = 'P0409'; end if;

  -- Verification and closure are restricted to the roles named in the proposal.
  if p_type = 'issue' and (p_payload->>'status') is distinct from (cur.payload->>'status') then
    if (p_payload->>'status') = 'verified' and r not in ('supervisor','inspector','projectManager') then
      raise exception 'role_not_permitted' using errcode = 'P0403'; end if;
    -- Closing needs a supervisor or project manager, except that a reviewer
    -- (inspector) may close an issue by dismissing a machine-generated flag.
    if (p_payload->>'status') = 'closed' and r not in ('supervisor','projectManager')
       and not (r = 'inspector' and (p_payload->>'review') = 'dismissed') then
      raise exception 'role_not_permitted' using errcode = 'P0403'; end if;
  end if;

  update records set payload = p_payload, sort_date = p_sort_date, parent_id = p_parent,
         object_path = coalesce(p_object_path, object_path), server_version = cur.server_version + 1,
         updated_at = now(), last_operation = p_operation
   where id = p_id;
  return cur.server_version + 1;
end $$;
revoke execute on function upsert_record(uuid, text, uuid, uuid, timestamptz, jsonb, text, numeric, uuid) from public, anon;
grant execute on function upsert_record(uuid, text, uuid, uuid, timestamptz, jsonb, text, numeric, uuid) to authenticated;

-- Evidence photos: private bucket, path = <project_id>/<photo_id>.jpg
insert into storage.buckets (id, name, public) values ('evidence', 'evidence', false) on conflict do nothing;
create policy evidence_read on storage.objects for select using (
  bucket_id = 'evidence' and is_member(((storage.foldername(name))[1])::uuid));
create policy evidence_write on storage.objects for insert with check (
  bucket_id = 'evidence' and is_member(((storage.foldername(name))[1])::uuid));
create policy evidence_update on storage.objects for update using (
  bucket_id = 'evidence' and is_member(((storage.foldername(name))[1])::uuid));

-- Realtime: broadcast row changes so other devices update without polling.
alter publication supabase_realtime add table records;
