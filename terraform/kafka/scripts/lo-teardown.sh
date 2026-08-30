#!/bin/bash
#
# lo-setup.sh の後始末。
#   - /etc/hosts のマーカーブロックを削除
#   - lo0 の 127.0.0.2..N エイリアスを削除
# sudo が必要。
#
#   sudo bash lo-teardown.sh
#
set -euo pipefail

HOSTS=/etc/hosts
MARKER_BEGIN="# >>> stream-iot-data-to-snowflake MSK local tunnel >>>"
MARKER_END="# <<< stream-iot-data-to-snowflake MSK local tunnel <<<"

# マーカーブロック内 + マーカー外でも「127.0.0.x <...kafka...amazonaws.com>」の行で
# 使っているループバック IP を回収する(手作業で足した行も拾う)
IPS="$(awk '/^127\.0\.0\.[0-9]+[ \t].*kafka.*amazonaws\.com/{print $1}' "$HOSTS" | sort -u || true)"

tmp="$(mktemp)"
awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
  $0==b{skip=1;next} $0==e{skip=0;next} skip{next}
  /^127\.0\.0\.[0-9]+[ \t].*kafka.*amazonaws\.com/{next}
  /MSK .*local SSH tunnel/{next}
  {print}' "$HOSTS" > "$tmp"
cat "$tmp" > "$HOSTS"
rm -f "$tmp"

for ip in $IPS; do
  [ "$ip" = "127.0.0.1" ] && continue
  ifconfig lo0 -alias "$ip" 2>/dev/null || true
  echo "removed lo0 alias $ip"
done

echo "残っている MSK 用 hosts 行:"; grep -n 'kafka.*amazonaws.com' "$HOSTS" || echo "  (なし)"
