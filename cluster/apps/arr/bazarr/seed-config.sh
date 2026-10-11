#!/bin/sh
# Seeds Bazarr's config.yaml on every start. Bazarr fills in all other keys
# with defaults on startup and rewrites the file, so a partial file is fine.
# Form login: Bazarr compares md5(password) as hex against auth.password
# (utilities/helper.py check_credentials), so the hash is stored here.
set -eu

dir=/config/config
file="$dir/config.yaml"

mkdir -p "$dir"
if [ ! -s "$file" ]; then
  echo "creating $file"
  echo '{}' > "$file"
fi

UI_PASSWORD_MD5=$(printf '%s' "$UI_PASSWORD" | md5sum | cut -d ' ' -f 1)
export UI_PASSWORD_MD5

echo "setting form auth, auth.apikey and the sonarr connection in $file"
yq -i '
  .auth.type = "form" |
  .auth.username = strenv(UI_USERNAME) |
  .auth.password = strenv(UI_PASSWORD_MD5) |
  .auth.apikey = strenv(BAZARR_API_KEY) |
  .general.use_sonarr = true |
  .sonarr.ip = "sonarr.arr.svc.cluster.local" |
  .sonarr.port = 8080 |
  .sonarr.base_url = "/" |
  .sonarr.ssl = false |
  .sonarr.apikey = strenv(SONARR_API_KEY)
' "$file"

# Runs as root (the PVC dir starts root-owned); hand it to the linuxserver user.
chown -R 2000:2000 "$dir"
