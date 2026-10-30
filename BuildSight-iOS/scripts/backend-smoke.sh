#!/bin/zsh
# Checks a Supabase project against what the app expects. Read-only apart from one write
# the server must refuse, so nothing is left behind.
#
#   BS_EMAIL=you@example.com BS_PASSWORD='…' scripts/backend-smoke.sh
#
# Uses the URL and key from Config/. Your password comes from the environment and is only
# sent to your own project.
set -uo pipefail
cd "$(dirname "$0")/.."
URL=$(grep BACKEND_URL Config/Secrets.xcconfig | sed 's/.*= *//; s|https:/\$()/|https://|')
KEY=$(grep ANON_KEY Config/Secrets.xcconfig | sed 's/.*= *//')
: "${BS_EMAIL:?set BS_EMAIL}"; : "${BS_PASSWORD:?set BS_PASSWORD}"
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1 -- $2"; fail=$((fail+1)); }
j() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

login=$(curl -s -m 30 -X POST "$URL/auth/v1/token?grant_type=password" -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,os; print(json.dumps({"email":os.environ["BS_EMAIL"],"password":os.environ["BS_PASSWORD"]}))')")
TOKEN=$(echo "$login" | j 'd["access_token"]'); UID_=$(echo "$login" | j 'd["user"]["id"]')
if [[ -n "$TOKEN" ]]; then ok "sign-in returns a session for $BS_EMAIL"; else bad "sign-in" "$(echo "$login" | cut -c1-200)"; echo "---- $pass passed, $fail failed"; exit 1; fi

bad_login=$(curl -s -m 30 -o /dev/null -w "%{http_code}" -X POST "$URL/auth/v1/token?grant_type=password" -H "apikey: $KEY" -H "Content-Type: application/json" -d '{"email":"nobody@example.invalid","password":"wrong-password"}')
[[ "$bad_login" == "400" ]] && ok "wrong credentials are refused (400)" || bad "wrong credentials" "HTTP $bad_login"

H=(-H "apikey: $KEY" -H "Authorization: Bearer $TOKEN")
me=$(curl -s -m 30 "${H[@]}" "$URL/auth/v1/user"); [[ "$(echo "$me" | j 'd["email"]')" == "$BS_EMAIL" ]] && ok "auth/v1/user returns the email" || bad "auth/v1/user" "$me"

prof=$(curl -s -m 30 "${H[@]}" "$URL/rest/v1/profiles?id=eq.$UID_&select=display_name,organisations(name)")
[[ "$(echo "$prof" | j 'len(d)')" == "1" ]] && ok "profile row with organisation embed ($(echo "$prof" | j 'd[0]["display_name"]'))" || bad "profile" "$prof"

mem=$(curl -s -m 30 "${H[@]}" "$URL/rest/v1/memberships?user_id=eq.$UID_&select=project_id,role")
PID=$(echo "$mem" | j 'd[0]["project_id"]'); ROLE=$(echo "$mem" | j 'd[0]["role"]')
[[ -n "$PID" ]] && ok "membership found: role $ROLE" || bad "membership" "$mem"

if [[ -n "$PID" ]]; then
  recs=$(curl -s -m 30 "${H[@]}" "$URL/rest/v1/records?project_id=eq.$PID&select=type,server_version,updated_at,sort_date,payload&limit=1000")
  summary=$(echo "$recs" | j '{t:[r["type"] for r in d].count(t) for t in set(r["type"] for r in d)}')
  echo "      records visible: $summary"
  echo "$recs" | j '"project" in {r["type"] for r in d} and "siteArea" in {r["type"] for r in d}' | grep -q True && ok "project and site-area reference rows are readable" || bad "reference rows" "seed not applied?"

  direct=$(curl -s -m 30 -o /dev/null -w "%{http_code}" -X POST "${H[@]}" -H "Content-Type: application/json" "$URL/rest/v1/records" -d "{\"id\":\"$(uuidgen | tr A-Z a-z)\",\"type\":\"issue\",\"project_id\":\"$PID\",\"sort_date\":\"2026-01-01T00:00:00Z\",\"payload\":{}}")
  [[ "$direct" == "401" || "$direct" == "403" ]] && ok "direct insert into records is refused ($direct)" || bad "direct insert" "HTTP $direct (writes must go through upsert_record)"

  rpc=$(curl -s -m 30 -X POST "${H[@]}" -H "Content-Type: application/json" "$URL/rest/v1/rpc/upsert_record" \
    -d "{\"p_id\":\"$(uuidgen | tr A-Z a-z)\",\"p_type\":\"project\",\"p_project\":\"$PID\",\"p_parent\":null,\"p_sort_date\":\"2026-01-01T00:00:00Z\",\"p_payload\":{},\"p_object_path\":null,\"p_base_version\":0,\"p_operation\":\"$(uuidgen | tr A-Z a-z)\"}")
  echo "$rpc" | grep -q "role_not_permitted" && ok "upsert_record exists and refuses to write reference data" || bad "upsert_record" "$(echo "$rpc" | cut -c1-200)"
fi

anon=$(curl -s -m 30 -H "apikey: $KEY" -H "Authorization: Bearer $KEY" "$URL/rest/v1/records?select=id&limit=1")
[[ "$anon" == "[]" ]] && ok "signed-out (anon key) sees no records" || bad "anon read" "$(echo "$anon" | cut -c1-200)"

echo "---- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
