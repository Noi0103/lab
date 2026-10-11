#!/bin/bash
# Wires the arr apps together through their APIs. Runs every 15 minutes from
# the arr-config CronJob and only writes when something differs.
# Bazarr (login and Bazarr -> Sonarr) is not done here; bazarr's init
# container seeds its config.yaml.
set -euo pipefail
shopt -s inherit_errexit

SONARR_URL=http://sonarr.arr.svc.cluster.local:8080
PROWLARR_URL=http://prowlarr.arr.svc.cluster.local:9696

QBT_HOST=qbittorrent.gluetun.svc.cluster.local
QBT_PORT=8080
QBT_CATEGORY=tv-sonarr

ROOT_FOLDER=/media/tv

# Logs go to stderr so they never mix with API output captured from stdout.
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

wait_for() { # name url
  local name=$1 url=$2 i
  # Short on purpose: the CronJob retries every 15 minutes anyway.
  for i in $(seq 1 12); do
    if curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; then
      log "$name is up"
      return 0
    fi
    log "waiting for $name at $url ($i/12)"
    sleep 5
  done
  log "ERROR: $name did not come up, giving up until the next run"
  return 1
}

# api METHOD BASE_URL API_KEY PATH [BODY] -> prints the response body.
# On HTTP errors it logs only the validation messages (never the request
# body or attemptedValue, which can contain API keys) and fails.
api() {
  local method=$1 base=$2 key=$3 path=$4 body=${5:-} out status
  local args=(-sS --max-time 30 -X "$method" -H "X-Api-Key: $key" -H 'Accept: application/json' -w '\n%{http_code}')
  if [[ -n $body ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$body")
  fi
  out=$(curl "${args[@]}" "$base$path")
  status=${out##*$'\n'}
  out=${out%$'\n'*}
  if ((status < 200 || status >= 300)); then
    log "ERROR: $method ${path%%\?*} -> HTTP $status: $(jq -r '
      if type == "array" then map("\(.propertyName // ""): \(.errorMessage // "")") | join("; ")
      else (.message // .description // "no message") end' <<<"$out" 2>/dev/null || printf '%.300s' "$out")"
    return 1
  fi
  printf '%s' "$out"
}

# upsert LABEL BASE_URL API_KEY ENDPOINT PAYLOAD
# Matches by .name. Existing entries keep fields we do not manage; ours win.
# forceSave=true skips the connection test (the target may not be ready yet).
# Unchanged entries are not re-PUT (a PUT of a Prowlarr app triggers a sync).
# Private fields come back as "********" and count as unchanged, so a rotated
# API key/password is only pushed together with another change (or by
# deleting the entry in the UI).
upsert() {
  local label=$1 base=$2 key=$3 endpoint=$4 payload=$5 name cur id body
  name=$(jq -r .name <<<"$payload")
  cur=$(api GET "$base" "$key" "$endpoint" | jq -c --arg n "$name" 'first(.[] | select(.name == $n)) // empty')
  if [[ -n $cur ]]; then
    id=$(jq -r .id <<<"$cur")
    if jq -e --argjson want "$payload" '
      . as $cur
      | all($want | del(.fields) | to_entries[]; $cur[.key] == .value)
        and all($want.fields[]; . as $w
          | (first($cur.fields[] | select(.name == $w.name)) // null) as $c
          | $c.value == $w.value or $c.value == "********")
    ' <<<"$cur" >/dev/null; then
      log "$label: up to date (id $id)"
      return 0
    fi
    body=$(jq -c --argjson want "$payload" '
      . as $cur
      | ($want.fields | map(.name)) as $ours
      | $cur + ($want | del(.fields))
      | .id = $cur.id
      | .fields = ([$cur.fields[] | select(.name as $n | $ours | index($n) | not)] + $want.fields)
    ' <<<"$cur")
    api PUT "$base" "$key" "$endpoint/$id?forceSave=true" "$body" >/dev/null
    log "$label: updated (id $id)"
  else
    api POST "$base" "$key" "$endpoint?forceSave=true" "$payload" >/dev/null
    log "$label: created"
  fi
}

# ensure_ui_login LABEL BASE_URL API_KEY HOST_CONFIG_PATH
# Creates/updates the single forms-auth user. With AUTH__METHOD=Forms from env
# and no user in a fresh database, the UI would reject every login (the
# first-run "create user" dialog only opens when auth is none).
# Skips the PUT when the username matches and a test login succeeds.
ensure_ui_login() {
  local label=$1 base=$2 key=$3 path=$4 cur redirect body
  cur=$(api GET "$base" "$key" "$path")
  # POST /login answers with a redirect; a failed login goes to ...&loginFailed=true.
  redirect=$(curl -sS --max-time 10 -o /dev/null -w '%{redirect_url}' \
    --data-urlencode "username=$UI_USERNAME" --data-urlencode "password=$UI_PASSWORD" "$base/login")
  if [[ -n $redirect && $redirect != *loginFailed* ]] &&
    jq -e --arg u "$UI_USERNAME" '
      .authenticationMethod == "forms" and .authenticationRequired == "enabled"
      and .username == ($u | ascii_downcase)' <<<"$cur" >/dev/null; then
    log "$label: UI login up to date"
    return 0
  fi
  # Sonarr stores the username lowercased; the password is hashed server-side.
  body=$(jq -c --arg u "$UI_USERNAME" --arg p "$UI_PASSWORD" '
    .authenticationMethod = "forms" | .authenticationRequired = "enabled"
    | .username = $u | .password = $p | .passwordConfirmation = $p' <<<"$cur")
  api PUT "$base" "$key" "$path/$(jq -r .id <<<"$cur")" "$body" >/dev/null
  log "$label: UI login set"
}

wait_for sonarr "$SONARR_URL/ping"
wait_for prowlarr "$PROWLARR_URL/ping"

# --- UI logins ----------------------------------------------------------------
ensure_ui_login sonarr "$SONARR_URL" "$SONARR_API_KEY" /api/v3/config/host
ensure_ui_login prowlarr "$PROWLARR_URL" "$PROWLARR_API_KEY" /api/v1/config/host

# --- Prowlarr -> Sonarr ------------------------------------------------------
log "prowlarr: ensuring application Sonarr (fullSync)"
upsert "prowlarr application Sonarr" "$PROWLARR_URL" "$PROWLARR_API_KEY" /api/v1/applications "$(
  jq -n --arg prowlarr "$PROWLARR_URL" --arg sonarr "$SONARR_URL" --arg key "$SONARR_API_KEY" '{
    name: "Sonarr",
    implementation: "Sonarr",
    configContract: "SonarrSettings",
    syncLevel: "fullSync",
    tags: [],
    fields: [
      {name: "prowlarrUrl", value: $prowlarr},
      {name: "baseUrl", value: $sonarr},
      {name: "apiKey", value: $key},
      {name: "syncCategories", value: [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5090]},
      {name: "animeSyncCategories", value: [5070]}
    ]
  }'
)"

# --- Sonarr root folder -------------------------------------------------------
mkdir -p "$ROOT_FOLDER"
folders=$(api GET "$SONARR_URL" "$SONARR_API_KEY" /api/v3/rootfolder)
if jq -e --arg p "$ROOT_FOLDER" 'any(.[]; (.path | rtrimstr("/")) == $p)' >/dev/null <<<"$folders"; then
  log "sonarr: root folder $ROOT_FOLDER already exists"
else
  api POST "$SONARR_URL" "$SONARR_API_KEY" /api/v3/rootfolder "$(jq -n --arg p "$ROOT_FOLDER" '{path: $p}')" >/dev/null
  log "sonarr: root folder $ROOT_FOLDER created"
fi

# --- Sonarr -> qBittorrent ----------------------------------------------------
if [[ -z ${QBITTORRENT_USERNAME:-} || -z ${QBITTORRENT_PASSWORD:-} ]]; then
  # Picked up on the next run once both keys are added to secret arr.
  log "sonarr: skipping qBittorrent download client (qbittorrent_username/qbittorrent_password not in secret arr yet)"
else
  log "sonarr: ensuring download client qBittorrent"
  upsert "sonarr download client qBittorrent" "$SONARR_URL" "$SONARR_API_KEY" /api/v3/downloadclient "$(
    jq -n --arg host "$QBT_HOST" --argjson port "$QBT_PORT" --arg cat "$QBT_CATEGORY" \
      --arg user "$QBITTORRENT_USERNAME" --arg pass "$QBITTORRENT_PASSWORD" '{
      name: "qBittorrent",
      enable: true,
      protocol: "torrent",
      priority: 1,
      removeCompletedDownloads: true,
      removeFailedDownloads: true,
      implementation: "QBittorrent",
      configContract: "QBittorrentSettings",
      tags: [],
      fields: [
        {name: "host", value: $host},
        {name: "port", value: $port},
        {name: "useSsl", value: false},
        {name: "urlBase", value: ""},
        {name: "username", value: $user},
        {name: "password", value: $pass},
        {name: "tvCategory", value: $cat}
      ]
    }'
  )"
fi

log "done"
