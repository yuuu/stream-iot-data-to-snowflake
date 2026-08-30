#!/bin/bash
# AmazonMSK_env-sensor_karafka シークレットを Secrets Manager から取得し、
# karafka/.env を生成する(.env は gitignore 対象。認証情報はコミットしない)。
#
# 使い方: AWS_PROFILE=fusic-sandbox bash bin/load-secret.sh
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
SECRET_ID="${SECRET_ID:-AmazonMSK_env-sensor_karafka}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$HERE/.env"

json="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ID" --query SecretString --output text)"
user="$(printf '%s' "$json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["username"])')"
pass="$(printf '%s' "$json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')"

cat > "$ENV_FILE" <<EOF
KAFKA_SASL_USERNAME=$user
KAFKA_SASL_PASSWORD=$pass
KAFKA_BOOTSTRAP=b-1.envsensorkafka.2ci9mq.c4.kafka.ap-northeast-1.amazonaws.com:9096,b-2.envsensorkafka.2ci9mq.c4.kafka.ap-northeast-1.amazonaws.com:9096,b-3.envsensorkafka.2ci9mq.c4.kafka.ap-northeast-1.amazonaws.com:9096
KAFKA_SSL_CA_LOCATION=/etc/ssl/cert.pem
EOF
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE (user=$user, password hidden)"
