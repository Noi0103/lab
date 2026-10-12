#!/bin/bash
# Local only: sets qBittorrent's WebUI login to the credentials Sonarr uses
# (arr secret, copied into the gluetun Secret by local/cluster.sh). On prod the
# login was set by hand; a fresh local PVC would otherwise get a random one.
# Runs as root from linuxserver's /custom-cont-init.d before qBittorrent starts.
set -euo pipefail

python3 - /config/qBittorrent/qBittorrent.conf /run/qbittorrent-login <<'EOF'
import base64, configparser, hashlib, hmac, os, sys

conf, creds = sys.argv[1], sys.argv[2]
user = open(os.path.join(creds, "qbittorrent_username")).read().strip()
password = open(os.path.join(creds, "qbittorrent_password")).read().strip().encode()

def pbkdf2(salt):
    return hashlib.pbkdf2_hmac("sha512", password, salt, 100000, 64)

cp = configparser.RawConfigParser(delimiters=("=",), strict=False)
cp.optionxform = str
cp.read(conf)
prefs = cp["Preferences"]

# Keep an existing hash of the same password, so the file only changes once.
current = prefs.get("WebUI\\Password_PBKDF2", "").strip('"')
if prefs.get("WebUI\\Username") == user and current.startswith("@ByteArray("):
    salt, key = (base64.b64decode(p) for p in current[len("@ByteArray("):-1].split(":"))
    if hmac.compare_digest(pbkdf2(salt), key):
        sys.exit(0)

salt = os.urandom(16)
prefs["WebUI\\Username"] = user
prefs["WebUI\\Password_PBKDF2"] = '"@ByteArray({}:{})"'.format(
    base64.b64encode(salt).decode(), base64.b64encode(pbkdf2(salt)).decode())
with open(conf, "w") as f:
    cp.write(f, space_around_delimiters=False)
print("qbittorrent-login: WebUI login set for", user)
EOF
