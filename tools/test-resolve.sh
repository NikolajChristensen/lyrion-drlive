#!/usr/bin/env bash
# End-to-end check of the DRLive resolution chain, without Lyrion:
#   anonymous token -> items/<id> -> customFields.hlsURL -> lowest variant -> ffmpeg -> flac
# Usage: tools/test-resolve.sh [channel-id]   (default 20876 = DR2)
set -euo pipefail

ID="${1:-20876}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "1. anonymous token"
TOKEN=$(curl -sf --compressed \
  'https://isl.dr-massive.com/api/authorization/anonymous-sso?device=web_browser&lang=da&supportFallbackToken=true' \
  -H 'content-type: application/json' \
  --data "{\"deviceId\":\"$(cat /proc/sys/kernel/random/uuid)\",\"scopes\":[\"Catalog\"],\"optout\":true}" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(next(x['value'] for x in d if x.get('type')=='UserAccount'))")
echo "   token length: ${#TOKEN}"

echo "2. items/$ID"
curl -sf --compressed \
  "https://production-cdn.dr-massive.com/api/items/${ID}?device=web_browser&expand=all&ff=idp,ldp,rpt&geoLocation=dk&isDeviceAbroad=false&lang=da&segments=drtv,optedout&sub=Anonymous" \
  -H "authorization: Bearer $TOKEN" > "$TMP/item.json"
TITLE=$(python3 -c "import json;print(json.load(open('$TMP/item.json'))['title'])")
MASTER=$(python3 -c "import json;print(json.load(open('$TMP/item.json'))['customFields']['hlsURL'])")
echo "   title : $TITLE"
echo "   master: $MASTER"

echo "3. lowest-bandwidth variant"
curl -sf "$MASTER" > "$TMP/master.m3u8"
cat > "$TMP/pick.py" <<'PY'
import sys, re, urllib.parse
base = sys.argv[1]
lines = open(sys.argv[2]).read().splitlines()
best = None
for i, l in enumerate(lines):
    if l.startswith('#EXT-X-STREAM-INF:'):
        m = re.search(r'[:,]BANDWIDTH=(\d+)', l)
        bw = int(m.group(1)) if m else 0
        uri = next((x for x in lines[i+1:] if x and not x.startswith('#')), None)
        if uri and (best is None or bw < best[0]):
            best = (bw, uri)
if not best:
    sys.exit("no EXT-X-STREAM-INF variants found")
print(urllib.parse.urljoin(base, best[1]))
PY
VARIANT=$(python3 "$TMP/pick.py" "$MASTER" "$TMP/master.m3u8")
echo "   variant: $VARIANT"

echo "4. ffmpeg -> flac (10s)"
ffmpeg -loglevel error -nostdin -i "$VARIANT" -vn -c:a flac -compression_level 0 -f flac -t 10 -y "$TMP/out.flac"
ffprobe -loglevel error -show_entries stream=codec_name,sample_rate,channels -of default=nw=1 "$TMP/out.flac"
echo "   size: $(stat -c%s "$TMP/out.flac") bytes"
echo
echo "OK - channel $ID ($TITLE) resolves and decodes."
