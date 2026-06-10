#!/usr/bin/env bash
# Add PocketBase autodate `created`/`updated` fields to the `tasks` collection and
# backfill `updated` on existing records.
#
# WHY: the iOS pull cursor (spec §7.1 cursor exception, 2026-06-10) filters pulls on
# `updated >= cursor`. PocketBase ≥ 0.23 makes created/updated OPTIONAL per-collection
# autodate fields, and adding them does NOT backfill existing rows — an old record with
# an empty `updated` would never match the filter, so a fresh device would silently
# miss it. The backfill re-saves each unstamped record, which fires the onUpdate
# autodate. (Re-saves emit realtime `update` events; clients apply them as LWW no-ops
# because `client_updated_at` is unchanged.)
#
# Usage:   ./scripts/pb-add-autodate-fields.sh <pocketbase-url> <superuser-email>
# Example: ./scripts/pb-add-autodate-fields.sh https://api.vinny.io you@example.com
# Prompts for the superuser password. Idempotent — safe to re-run; the backfill only
# touches records whose `updated` is still empty.

set -euo pipefail

BASE_URL="${1:?usage: $0 <pocketbase-url> <superuser-email>}"
EMAIL="${2:?usage: $0 <pocketbase-url> <superuser-email>}"
BASE_URL="${BASE_URL%/}"

command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }

read -r -s -p "Superuser password for ${EMAIL}: " PASSWORD; echo

# --- 1) Superuser auth (PB ≥ 0.23 path, with the legacy /api/admins fallback) -------
auth() {
  curl -sf "${BASE_URL}$1" -H 'Content-Type: application/json' \
    -d "{\"identity\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}" | jq -r .token
}
TOKEN=$(auth "/api/collections/_superusers/auth-with-password" || true)
if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  TOKEN=$(auth "/api/admins/auth-with-password" || true)
fi
[ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] || { echo "✗ auth failed"; exit 1; }
echo "✓ authenticated"

# --- 2) Add the autodate fields if missing (PATCH sends the FULL fields array) ------
COLLECTION=$(curl -sf "${BASE_URL}/api/collections/tasks" -H "Authorization: ${TOKEN}")
HAS_CREATED=$(echo "${COLLECTION}" | jq '[.fields[] | select(.name == "created" and .type == "autodate")] | length')
HAS_UPDATED=$(echo "${COLLECTION}" | jq '[.fields[] | select(.name == "updated" and .type == "autodate")] | length')

if [ "${HAS_CREATED}" -eq 1 ] && [ "${HAS_UPDATED}" -eq 1 ]; then
  echo "✓ tasks already has autodate created/updated — skipping schema change"
else
  FIELDS=$(echo "${COLLECTION}" | jq '.fields')
  if [ "${HAS_CREATED}" -eq 0 ]; then
    FIELDS=$(echo "${FIELDS}" | jq '. + [{"name":"created","type":"autodate","onCreate":true,"onUpdate":false}]')
  fi
  if [ "${HAS_UPDATED}" -eq 0 ]; then
    FIELDS=$(echo "${FIELDS}" | jq '. + [{"name":"updated","type":"autodate","onCreate":true,"onUpdate":true}]')
  fi
  curl -sf -X PATCH "${BASE_URL}/api/collections/tasks" \
    -H "Authorization: ${TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"fields\": ${FIELDS}}" >/dev/null
  echo "✓ added autodate field(s) to tasks"
fi

# --- 3) Backfill: re-save every record whose `updated` is still empty ---------------
# Always request page 1 — each re-save removes the record from the filtered set.
BACKFILLED=0
while :; do
  PAGE=$(curl -sfG "${BASE_URL}/api/collections/tasks/records" \
    -H "Authorization: ${TOKEN}" \
    --data-urlencode 'perPage=200' \
    --data-urlencode 'filter=updated = ""')
  IDS=$(echo "${PAGE}" | jq -r '.items[].id')
  [ -n "${IDS}" ] || break
  for id in ${IDS}; do
    curl -sf -X PATCH "${BASE_URL}/api/collections/tasks/records/${id}" \
      -H "Authorization: ${TOKEN}" -H 'Content-Type: application/json' \
      -d '{}' >/dev/null
    BACKFILLED=$((BACKFILLED + 1))
    printf '\r  backfilled %d record(s)…' "${BACKFILLED}"
  done
done
[ "${BACKFILLED}" -gt 0 ] && echo || echo "✓ no records needed backfilling"

# --- 4) Verify with the EXACT filter+sort the iOS app sends -------------------------
TOTAL=$(curl -sfG "${BASE_URL}/api/collections/tasks/records" \
  -H "Authorization: ${TOKEN}" --data-urlencode 'perPage=1' | jq .totalItems)
MATCHED=$(curl -sfG "${BASE_URL}/api/collections/tasks/records" \
  -H "Authorization: ${TOKEN}" \
  --data-urlencode 'perPage=1' \
  --data-urlencode 'sort=updated' \
  --data-urlencode 'filter=updated >= "1970-01-01 00:00:00.000Z"' | jq .totalItems)

echo "✓ verification: ${MATCHED}/${TOTAL} records match the iOS pull filter"
if [ "${MATCHED}" != "${TOTAL}" ]; then
  echo "✗ MISMATCH — some records would be invisible to the iOS pull. Re-run the script;"
  echo "  if it persists, inspect: filter=updated = \"\" in the PB admin UI."
  exit 1
fi
echo "Done. The iOS server-stamped cursor (Fix B) is now safe to ship against this instance."
