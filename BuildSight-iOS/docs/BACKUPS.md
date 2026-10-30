# Backups

The free Supabase plan keeps no backups, so one wrong update can't be undone from the dashboard.
`Backend/supabase/backup.sh` exports the data to a compressed SQL file and keeps the newest 14.

## Take one

1. `brew install libpq && brew link --force libpq` (gives you `pg_dump`).
2. Supabase > Project Settings > Database > Connection string > URI. Copy it and put your database password in.
3. Run it (the connection string stays in your shell, not in a file):
   ```
   BS_DB_URL='postgresql://postgres:PASSWORD@db.PROJECTREF.supabase.co:5432/postgres' ./Backend/supabase/backup.sh ~/BuildSightBackups
   ```

Add `BS_INCLUDE_AUTH=1` to include user accounts. That file holds emails and password hashes, so keep it private.

## Run it automatically

Run `crontab -e` and add a daily line (Mac asleep at that time means it skips that day):
```
0 18 * * * BS_DB_URL='postgresql://...' /path/to/buildsight-ios/BuildSight-iOS/Backend/supabase/backup.sh ~/BuildSightBackups
```

## What it does not cover

- **Evidence photos** in Supabase Storage are not in the SQL file. Photos also stay on the phone that took them until synced.
- **Restoring**: create a fresh project, run `schema.sql`, then `gunzip -c backup.sql.gz | psql "$BS_DB_URL"`.
- **Before any manual SQL change**, take a backup first.
