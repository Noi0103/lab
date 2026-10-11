#!/bin/bash
# Runs before Configarr, which does not manage host config: creates the
# Sonarr root folder on the media share and sets each app's forms login and
# certificate validation (stored in the app DB, no env var exists for it).
set -euo pipefail
mkdir -p /media/library/shows
c() { curl -fsS --max-time 20 --retry 12 --retry-delay 5 --retry-all-errors ${CURL_INSECURE:+-k} "$@"; }
for app in sonarr/v3/"$SONARR_API_KEY" prowlarr/v1/"$PROWLARR_API_KEY"; do
  IFS=/ read -r name ver key <<<"$app"
  url="https://$name.$EXTERNAL_DOMAIN" api="/api/$ver/config/host"
  cfg=$(c -H "X-Api-Key: $key" "$url$api")
  # A failed POST /login redirects to ...loginFailed=true; skip the PUT (which re-hashes the password) if all is set.
  login=$(c -o /dev/null -w '%{redirect_url}' --data-urlencode "username=$UI_USERNAME" --data-urlencode "password=$UI_PASSWORD" "$url/login")
  if [[ $login != *loginFailed* ]] && jq -e --arg u "${UI_USERNAME,,}" --arg cv "${CERT_VALIDATION:-enabled}" \
    '.authenticationMethod == "forms" and .username == $u and .certificateValidation == $cv' <<<"$cfg" >/dev/null; then
    echo "$name: host config up to date"; continue
  fi
  jq --arg u "$UI_USERNAME" --arg p "$UI_PASSWORD" --arg cv "${CERT_VALIDATION:-enabled}" \
    '.authenticationMethod = "forms" | .authenticationRequired = "enabled" | .username = $u
     | .password = $p | .passwordConfirmation = $p | .certificateValidation = $cv' <<<"$cfg" |
    c -X PUT -H "X-Api-Key: $key" -H 'Content-Type: application/json' --data-binary @- "$url$api/$(jq -r .id <<<"$cfg")" >/dev/null
  echo "$name: host config updated"
done
