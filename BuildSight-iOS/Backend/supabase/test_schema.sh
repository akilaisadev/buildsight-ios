#!/bin/zsh
# Runs schema.sql on a throwaway local PostgreSQL and checks the access rules.
#
# What this proves: the SQL parses and that upsert_record, row-level security
# and the storage policies behave as intended for different users.
# What it does NOT prove: anything about a real Supabase project. Supabase's
# auth and storage schemas are replaced here by minimal stand-ins (stubs.sql
# below), so JWT handling, PostgREST and Realtime are untested.
set -euo pipefail
PGBIN="${PGBIN:-/usr/local/opt/postgresql@16/bin}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
PORT="${PGPORT:-54329}"
trap '"$PGBIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$PGBIN/initdb" -D "$WORK/data" -U postgres --auth=trust --locale=C --encoding=UTF8 >/dev/null
"$PGBIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK" -l "$WORK/log" -w start >/dev/null
PSQL=("$PGBIN/psql" -h "$WORK" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q -X)
"${PSQL[@]}" -c "create database bs" >/dev/null
PSQL+=(-d bs)

"${PSQL[@]}" <<'SQL'
create role authenticated nologin; create role anon nologin;
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
create schema storage;
create table storage.buckets (id text primary key, name text, public boolean);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as
  $$ select (string_to_array(name, '/'))[1:cardinality(string_to_array(name, '/')) - 1] $$;
grant usage on schema storage to authenticated;
grant all on storage.objects to authenticated;
create publication supabase_realtime;
SQL

"${PSQL[@]}" -f "${SCHEMA_FILE:-$HERE/schema.sql}"
"${PSQL[@]}" -c "grant usage on schema public to authenticated, anon; grant select on all tables in schema public to authenticated;"

"${PSQL[@]}" <<'SQL'
create table results (name text, ok boolean, detail text);
grant all on results to authenticated;

insert into organisations (id, name) values ('00000000-0000-0000-0000-0000000000a1', 'Acme');
insert into projects (id, organisation_id, payload) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', '{}'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1', '{}');
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'worker@x'), ('00000000-0000-0000-0000-000000000002', 'super@x'),
  ('00000000-0000-0000-0000-000000000003', 'inspector@x'), ('00000000-0000-0000-0000-000000000004', 'outsider@x');
insert into profiles (id, display_name, organisation_id) select id, email, '00000000-0000-0000-0000-0000000000a1' from auth.users;
insert into memberships values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000001', 'siteWorker'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000002', 'supervisor'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000003', 'inspector'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000004', 'siteWorker');
-- reference row inserted by the administrator (superuser), as in seed.sql
insert into records (id, type, project_id, sort_date, payload, created_by)
  values ('00000000-0000-0000-0000-0000000000c1', 'project', '00000000-0000-0000-0000-0000000000b1', now(), '{"name":"P"}', '00000000-0000-0000-0000-000000000002');

-- check(name, user, expected errmsg or null, sql)
create function expect(n text, uid uuid, err text, stmt text) returns void language plpgsql as $$
declare got text := null;
begin
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), false);
  execute 'set local role ' || (case when uid is null then 'anon' else 'authenticated' end);
  begin execute stmt; exception when others then got := sqlerrm; end;
  reset role;
  insert into results values (n, got is not distinct from err, 'expected ' || coalesce(err, 'success') || ' got ' || coalesce(got, 'success'));
end $$;
grant execute on function expect(text, uuid, text, text) to public;
SQL

W=00000000-0000-0000-0000-000000000001; S=00000000-0000-0000-0000-000000000002; I=00000000-0000-0000-0000-000000000003; O=00000000-0000-0000-0000-000000000004
P1=00000000-0000-0000-0000-0000000000b1
call() { # id type project payload base op
  echo "select upsert_record('$1','$2','$P1',null,now(),'$4'::jsonb,null,$5,'$6')"; }
ISS1=10000000-0000-0000-0000-000000000001
OPEN='{"status":"open","review":"notRequired"}'

run() {
  local uid="null" err="null"
  [[ -n "$2" ]] && uid="'$2'::uuid"
  [[ -n "$3" ]] && err="\$e\$$3\$e\$"
  "${PSQL[@]}" -c "select expect(\$n\$$1\$n\$, $uid, $err, \$q\$$4\$q\$)"
}
# usage: run name userid expected-error sql

run "worker creates an open issue"                 $W "" "$(call $ISS1 issue $P1 "$OPEN" 0 20000000-0000-0000-0000-000000000001)"
run "replay of the same operation is a no-op"      $W "" "$(call $ISS1 issue $P1 "$OPEN" 0 20000000-0000-0000-0000-000000000001)"
run "stale base version is a conflict"             $W "version_conflict" "$(call $ISS1 issue $P1 '{"status":"inProgress"}' 0 20000000-0000-0000-0000-000000000002)"
run "worker moves issue to inProgress"             $W "" "$(call $ISS1 issue $P1 '{"status":"inProgress"}' 1 20000000-0000-0000-0000-000000000003)"
run "worker cannot verify"                         $W "role_not_permitted" "$(call $ISS1 issue $P1 '{"status":"verified"}' 2 20000000-0000-0000-0000-000000000004)"
run "supervisor can verify"                        $S "" "$(call $ISS1 issue $P1 '{"status":"verified"}' 2 20000000-0000-0000-0000-000000000005)"
run "inspector cannot close a verified issue"      $I "role_not_permitted" "$(call $ISS1 issue $P1 '{"status":"closed","review":"confirmed"}' 3 20000000-0000-0000-0000-000000000006)"
run "inspector can close by dismissing a flag"     $I "" "$(call $ISS1 issue $P1 '{"status":"closed","review":"dismissed"}' 3 20000000-0000-0000-0000-000000000007)"
run "outsider cannot write to the project"         $O "not_a_member" "$(call 10000000-0000-0000-0000-000000000009 issue $P1 "$OPEN" 0 20000000-0000-0000-0000-000000000008)"
run "outsider cannot touch an existing record id"  $O "not_a_member" "$(call $ISS1 issue $P1 "$OPEN" 0 20000000-0000-0000-0000-000000000010)"
run "anonymous user is refused"                    "" "permission denied for function upsert_record" "$(call 10000000-0000-0000-0000-000000000011 issue $P1 "$OPEN" 0 20000000-0000-0000-0000-000000000011)"
run "new issue cannot start closed"                $W "role_not_permitted" "$(call 10000000-0000-0000-0000-000000000012 issue $P1 '{"status":"closed"}' 0 20000000-0000-0000-0000-000000000012)"
run "clients cannot write reference data"          $S "role_not_permitted" "$(call 10000000-0000-0000-0000-000000000013 project $P1 '{}' 0 20000000-0000-0000-0000-000000000013)"
run "clients cannot edit an existing project row"  $S "role_not_permitted" "$(call 00000000-0000-0000-0000-0000000000c1 project $P1 '{"name":"X"}' 1 20000000-0000-0000-0000-000000000014)"
run "version sent as 1.0 is accepted"              $W "" "select upsert_record('10000000-0000-0000-0000-000000000015','task','$P1',null,now(),'{\"x\":1}'::jsonb,null,0.0,'20000000-0000-0000-0000-000000000015')"
run "direct insert into records is denied"         $W "permission denied for table records" "insert into records (id,type,project_id,sort_date,payload) values (gen_random_uuid(),'issue','$P1',now(),'{}')"
run "direct update of records is denied"           $W "permission denied for table records" "update records set payload='{}'"
run "member reads own project's records"           $W "" "select 1/(case when count(*) >= 2 then 1 else 0 end) from records"
run "outsider reads no rows from that project"     $O "" "select 1/(case when count(*) = 0 then 1 else 0 end) from records"
run "member reads co-member profiles"              $W "" "select 1/(case when count(*) = 3 then 1 else 0 end) from profiles"
run "outsider sees only their own profile"         $O "" "select 1/(case when count(*) = 1 then 1 else 0 end) from profiles"
run "outsider cannot see the project"              $O "" "select 1/(case when count(*) = 0 then 1 else 0 end) from projects where id='$P1'"
run "member can upload evidence into own project"  $W "" "insert into storage.objects (bucket_id,name) values ('evidence','$P1/p1.jpg')"
run "outsider cannot upload into that project"     $O "new row violates row-level security policy for table \"objects\"" "insert into storage.objects (bucket_id,name) values ('evidence','$P1/p2.jpg')"
run "outsider cannot read that project's photos"   $O "" "select 1/(case when count(*) = 0 then 1 else 0 end) from storage.objects"

# Optional: SEED_SQL=<file from tools/make_seed.swift, built with users ...0001 and ...0002>
if [[ -n "${SEED_SQL:-}" ]]; then
  "${PSQL[@]}" -f "$SEED_SQL"
  run "seed loads and a member can read its areas and team" $W "" "select 1/(case when count(*) filter (where type='siteArea') = 3 and count(*) filter (where type='teamMember') = 2 then 1 else 0 end) from records"
  run "seeded project is readable under row-level security" $W "" "select 1/(case when count(*) >= 2 then 1 else 0 end) from projects"
fi

"${PSQL[@]}" -t -A -F ' | ' -c "select case when ok then 'PASS' else 'FAIL' end, name, case when ok then '' else detail end from results"
FAILS=$("${PSQL[@]}" -t -A -c "select count(*) from results where not ok")
TOTAL=$("${PSQL[@]}" -t -A -c "select count(*) from results")
echo "---- $((TOTAL - FAILS))/$TOTAL checks passed"
[[ "$FAILS" == "0" ]]
