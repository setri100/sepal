
#!/usr/bin/env bash

# config (super save hardcoded secrets + IDs). live on raspi on site so i guess that's ok

SPREADSHEET_ID="<secret_id>"
WORKSHEET_NAME="data"
STATUS_SHEET_NAME="status"
CREDS_JSON_PATH="<path_to_google_api_json>"

API_URL="https://chat.kiconnect.nrw/api/v1/chat/completions"
MODEL_NAME="Mistral Small 3.2 24B KI.Inferenz.nrw"
API_KEY="<ki connect api key>"

HOURS_BACK=12
SAMPLE_EVERY_N=2
LIGHT_LUX_THRESHOLD=500


# deps

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need jq
need python3
need date
need awk
need sed


# helpers

get_access_token() {
  python3 - <<'PY'
from google.oauth2.service_account import Credentials
from google.auth.transport.requests import Request
import os

creds_path = os.environ["CREDS_JSON_PATH"]
scopes = ["https://www.googleapis.com/auth/spreadsheets"]

creds = Credentials.from_service_account_file(creds_path, scopes=scopes)
creds.refresh(Request())
print(creds.token)
PY
}

iso_utc_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
iso_utc_cutoff() { date -u -d "${HOURS_BACK} hours ago" +"%Y-%m-%dT%H:%M:%SZ"; }

to_epoch() {
  local ts="$1"
  ts="$(echo "$ts" | sed -E 's/\.[0-9]+//; s/\+00:00$/Z/; s/\+0000$/Z/; s/[[:space:]]+$//')"
  date -u -d "$ts" +%s 2>/dev/null || echo ""
}

fetch_sheet_values_json() {
  local token="$1"
  local range="${WORKSHEET_NAME}!A1:ZZ"
  curl -sS \
    -H "Authorization: Bearer ${token}" \
    "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}/values/${range}?majorDimension=ROWS"
}

tsv_to_csv() {
  awk -F'\t' '{
    out=""
    for (i=1;i<=NF;i++){
      gsub(/"/, "\"\"", $i)
      field="\"" $i "\""
      out = (i==1)? field : out "," field
    }
    print out
  }'
}

# sheet helpers
sheets_get_values() {
  local token="$1"
  local range="$2"
  curl -sS \
    -H "Authorization: Bearer ${token}" \
    "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}/values/${range}?majorDimension=ROWS"
}

sheets_update_values() {
  local token="$1"
  local range="$2"
  local body_json="$3"
  curl -sS -X PUT \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}/values/${range}?valueInputOption=RAW" \
    -d "$body_json" >/dev/null
}

sheets_append_values() {
  local token="$1"
  local range="$2"
  local body_json="$3"
  curl -sS -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}/values/${range}:append?valueInputOption=RAW&insertDataOption=INSERT_ROWS" \
    -d "$body_json" >/dev/null
}

ensure_sheet_exists() {
  local token="$1"
  local sheet_name="$2"

  local exists
  exists="$(curl -sS -H "Authorization: Bearer ${token}" \
    "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}?fields=sheets(properties(title))" \
    | jq -r --arg n "$sheet_name" '.sheets[].properties.title | select(.==$n)' | head -n1
  )"

  if [[ -n "$exists" ]]; then
    return 0
  fi

  local req
  req="$(jq -n --arg title "$sheet_name" '{
    requests: [
      { addSheet: { properties: { title: $title } } }
    ]
  }')"

  curl -sS -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}:batchUpdate" \
    -d "$req" >/dev/null
}

ensure_status_header() {
  local token="$1"
  local sheet="$2"
  local header_range="${sheet}!A1:C1"

  local cur
  cur="$(sheets_get_values "$token" "$header_range" | jq -r '.values[0] // empty | @tsv' || true)"

  if [[ -z "$cur" || "$cur" != $'ts_utc\twindow_hours\tai_status' ]]; then
    local body
    body="$(jq -n '{ values: [["ts_utc","window_hours","ai_status"]] }')"
    sheets_update_values "$token" "$header_range" "$body"
  fi
}

append_status_row() {
  local token="$1"
  local sheet="$2"
  local ts="$3"
  local window_hours="$4"
  local status="$5"

  local body
  body="$(jq -n --arg ts "$ts" --arg wh "$window_hours" --arg st "$status" \
    '{ values: [[ $ts, $wh, $st ]] }'
  )"

  sheets_append_values "$token" "${sheet}!A:C" "$body"
}


extract_text_or_raw() {
  local resp="$1"

  # If not valid JSON, just return raw
  if ! printf "%s" "$resp" | jq -e . >/dev/null 2>&1; then
    printf "%s\n" "$resp"
    return 0
  fi
  
  # tring to parse the sht out of the json output
  local out
  out="$(printf "%s" "$resp" | jq -r '
    (.choices[0].message.content // empty),
    (.choices[0].message.content[0].text // empty),
    (.choices[0].text // empty),
    (.output_text // empty),
    (.error.message // empty)
  ' | awk 'NF{print; exit}')"

  if [[ -n "$out" ]]; then
    printf "%s\n" "$out"
  else
    printf "%s\n" "$resp"
  fi
}


# main

export CREDS_JSON_PATH

NOW_UTC="$(iso_utc_now)"
CUTOFF_UTC="$(iso_utc_cutoff)"
CUTOFF_EPOCH="$(to_epoch "$CUTOFF_UTC")"

TOKEN="$(get_access_token)"
VALUES_JSON="$(fetch_sheet_values_json "$TOKEN")"

mapfile -t ROWS_TSV < <(echo "$VALUES_JSON" | jq -r '.values[] | @tsv')

if ((${#ROWS_TSV[@]} < 2)); then
  echo "No data rows found in sheet (need header + at least one data row)." >&2
  exit 1
fi

HEADER_TSV="${ROWS_TSV[0]}"

FILTERED_TSV=()
idx=0
for ((i=1; i<${#ROWS_TSV[@]}; i++)); do
  row="${ROWS_TSV[$i]}"
  ts="$(echo "$row" | awk -F'\t' '{print $1}')"
  ep="$(to_epoch "$ts")"
  [[ -z "$ep" ]] && continue

  if (( ep >= CUTOFF_EPOCH )); then
    ((idx++))
    if (( (idx - 1) % SAMPLE_EVERY_N == 0 )); then
      FILTERED_TSV+=("$row")
    fi
  fi
done

if ((${#FILTERED_TSV[@]} == 0)); then
  echo "No rows found in the last ${HOURS_BACK} hours (cutoff=${CUTOFF_UTC})." >&2
  exit 1
fi

SUMMARY="$(awk -v thr="$LIGHT_LUX_THRESHOLD" -F'\t' '
BEGIN{ for (s=1;s<=5;s++){ nan[s]=0; prev_on[s]=-1 } }
function is_nan(x){ return (x=="" || x=="NaN" || x=="nan" || x=="NAN") }
{
  ts=$1
  for (s=1;s<=5;s++){
    temp=$(2 + (s-1)*3)
    hum=$(3 + (s-1)*3)
    lux=$(4 + (s-1)*3)

    if (is_nan(temp) || is_nan(hum) || is_nan(lux)) nan[s]++

    on = (!is_nan(lux) && lux+0 > thr) ? 1 : 0
    if (prev_on[s]==-1){ prev_on[s]=on }
    else if (on != prev_on[s]){
      evt = on ? "ON" : "OFF"
      events = events sprintf("sensor %d light %s at %s (lux=%s)\n", s, evt, ts, lux)
      prev_on[s]=on
    }
  }
}
END{
  for (s=1;s<=5;s++) printf("NaN rows (any of temp/hum/lux missing) sensor %d: %d\n", s, nan[s])
  if (events!="") printf("\nInferred light switch events (threshold %d lux):\n%s", thr, events)
  else printf("\nInferred light switch events (threshold %d lux): none detected\n", thr)
}
' < <(printf "%s\n" "${FILTERED_TSV[@]}"))"

CSV_BLOCK="$(
  { echo "$HEADER_TSV"; printf "%s\n" "${FILTERED_TSV[@]}"; } | tsv_to_csv
)"

# CREATE PROMPT!!
PROMPT="$(cat <<EOF
You are monitoring a plant growth cabinet sensor system with 5 sensors.
Each sensor has temperature (°C), humidity (%), and light (lux). Data is logged every ~5 minutes (NaN may happen when a read fails).

Task:
- Write ONLY 2–3 short sentences as a human-readable STATUS UPDATE.
- Do NOT list raw numbers.
- Mention if anything looks wrong (e.g. a sensor not sensing / frequent NaN / suspicious gaps).
- Mention inferred light behavior in plain language (e.g. "lights turned on around 06:00", "lights have been off", "lights toggled").
- If everything looks fine, say so.

Context:
- Current time (UTC): ${NOW_UTC}
- Window: last ${HOURS_BACK} hours (cutoff UTC: ${CUTOFF_UTC})
- Lux threshold for "light on": > ${LIGHT_LUX_THRESHOLD}

Quick computed hints (based on the window):
${SUMMARY}

Raw data (CSV, first row is header, following rows are time series):
${CSV_BLOCK}
EOF
)"

REQ_JSON="$(jq -n --arg model "$MODEL_NAME" --arg content "$PROMPT" \
  '{ model: $model, messages: [ {role:"user", content:$content} ] }'
)"

TMP_RESP="$(mktemp)"
HTTP_CODE="$(curl -sS -o "$TMP_RESP" -w "%{http_code}" "$API_URL" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$REQ_JSON"
)"
RESP="$(cat "$TMP_RESP")"
rm -f "$TMP_RESP"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "API returned HTTP $HTTP_CODE" >&2
  echo "Response body:" >&2
  echo "$RESP" >&2
  exit 1
fi

OUT="$(extract_text_or_raw "$RESP")"

printf "%s\n" "$OUT"

# write into status sheet
ensure_sheet_exists "$TOKEN" "$STATUS_SHEET_NAME"
ensure_status_header "$TOKEN" "$STATUS_SHEET_NAME"
append_status_row "$TOKEN" "$STATUS_SHEET_NAME" "$NOW_UTC" "$HOURS_BACK" "$OUT"
