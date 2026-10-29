# Backend setup (Supabase)

The proposal specifies REST + realtime, PostgreSQL and object storage without naming a provider. Supabase provides exactly that (PostgREST, Realtime, Postgres, Storage, Auth with row-level security), so it is used as the realisation of the proposed design, not a replacement. If your lecturer expects a different provider, only `Remote/SupabaseClient.swift` and `schema.sql` change; everything above `RemoteBackend`/`AuthProvider` is provider-neutral.

1. Create a project at supabase.com (free tier is fine).
2. SQL editor → paste and run `Backend/supabase/schema.sql`.
3. Authentication → Users → **Add user** (email + password; tick *Auto Confirm User*, otherwise the project sends a confirmation email first). Create one user per role you want to demo and copy each user's **UID**.
4. Generate seed SQL with the app's own types (it validates the JSON shape before printing):
   ```
   swiftc -parse-as-library -o make-seed -I <kit build dir> -L <kit build dir> -lBuildSightKit Backend/supabase/tools/make_seed.swift
   ./make-seed --project "Tower A" --location "Site address" \
       --user <uid>:projectManager:"Alex Lee" --user <uid>:siteWorker:"Sam Tan" > seed.sql
   ```
   Run `seed.sql` in the SQL editor **once**. It creates the organisation, project, three site areas, the team and the memberships. Clients cannot write these reference rows; only the SQL editor can.
5. Settings → API Keys: put the project URL and the **publishable** key (`sb_publishable_…`) in `Config/Secrets.xcconfig`. Never use a `sb_secret_`/service-role key in the app.
6. Check it: `BS_EMAIL=… BS_PASSWORD=… scripts/backend-smoke.sh` (sign-in, profile, membership, reference rows, direct-write refused, RPC present).
7. Consider turning off *Allow new users to sign up* (Authentication → Providers → Email) so only users you add can sign in.
8. Storage: the schema creates a private `evidence` bucket.

Verified without a server: `Backend/supabase/test_schema.sh` runs `schema.sql` on a local PostgreSQL (with stand-ins for Supabase's auth/storage) and checks 25+ access rules; a deliberate weakening of two rules was caught. It does not test PostgREST, JWTs or Realtime.

Security model: clients cannot insert/update `records` directly. All writes go through `upsert_record()`, which checks membership, enforces verify/close roles, is idempotent on the operation id, and rejects stale versions (409) so the app can three-way merge.

Seed data is real server data you create; the app contains no hard-coded demo records.
