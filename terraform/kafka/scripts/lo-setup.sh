#!/bin/bash
#
# macOS でローカルから MSK ブローカーへ SSH ポートフォワード接続するための下準備。
#   - lo0 に 127.0.0.2, 127.0.0.3, ... のエイリアスを追加
#   - /etc/hosts に「各ブローカー FQDN -> 上記ループバック IP」を追記
# どちらも sudo が必要。後始末は lo-teardown.sh。
#
# ブローカー FQDN は引数で渡すか、未指定なら terraform output から取得する。
#   sudo bash lo-setup.sh
#   sudo bash lo-setup.sh b-1.xxx.kafka.ap-northeast-1.amazonaws.com b-2.xxx... b-3.xxx...
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$(cd "$HERE/.." && pwd)"
HOSTS=/etc/hosts
MARKER_BEGIN="# >>> stream-iot-data-to-snowflake MSK local tunnel >>>"
MARKER_END="# <<< stream-iot-data-to-snowflake MSK local tunnel <<<"

# --- ブローカー FQDN の一覧を用意 ---
if [ "$#" -gt 0 ]; then
  BROKERS=("$@")
else
  # terraform output（SASL/SCRAM bootstrap: "host:9096,host:9096,...")から FQDN を抽出
  BOOTSTRAP="$(terraform -chdir="$TF_DIR" output -raw msk_bootstrap_brokers_sasl_scram 2>/dev/null || true)"
  if [ -z "$BOOTSTRAP" ]; then
    echo "ブローカー FQDN を引数で渡すか、$TF_DIR で terraform apply 済みにしてください" >&2
    exit 1
  fi
  IFS=',' read -ra PAIRS <<< "$BOOTSTRAP"
  BROKERS=()
  for p in "${PAIRS[@]}"; do BROKERS+=("${p%%:*}"); done
fi

echo "対象ブローカー:"
printf '  %s\n' "${BROKERS[@]}"

# --- lo0 エイリアス + /etc/hosts 追記 ---
tmp="$(mktemp)"
grep -v -e "$MARKER_BEGIN" -e "$MARKER_END" "$HOSTS" \
  | awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
      $0==b{skip=1;next} $0==e{skip=0;next} !skip' > "$tmp" || true

{
  echo "$MARKER_BEGIN"
  i=2
  for host in "${BROKERS[@]}"; do
    ip="127.0.0.$i"
    ifconfig lo0 alias "$ip" up
    echo "$ip $host"
    i=$((i + 1))
  done
  echo "$MARKER_END"
} >> "$tmp"

cp "$HOSTS" "${HOSTS}.stream-iot.bak.$(date +%s)"
cat "$tmp" > "$HOSTS"
rm -f "$tmp"

echo
echo "lo0 エイリアス:"; ifconfig lo0 | grep 'inet 127' || true
echo "/etc/hosts:"; sed -n "/$MARKER_BEGIN/,/$MARKER_END/p" "$HOSTS"
echo
echo "次に SSH トンネルを張る(例):"
i=2
for host in "${BROKERS[@]}"; do
  echo "  -L 127.0.0.$i:9096:$host:9096 \\"
  i=$((i + 1))
done
echo "  ec2-user@<bastion-public-ip>"
