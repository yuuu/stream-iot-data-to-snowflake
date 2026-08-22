"""
SnowflakeのEgress IP(SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES())を取得し、
RDS(sensor_master)のセキュリティグループのingressルールへ同期するLambda。

Snowflake認証にはキーペア(RSA)+ JWTを使う。秘密鍵はSSM Parameter Store(SecureString)に
保存されており、このLambdaはSnowflakeへの読み取り専用アクセスしか持たない
(SGを書き換える権限はLambdaの実行ロール側にのみ存在する)。

キーペアにはPATと異なり有効期限がないため、失効に伴う定期再発行の運用は不要。
"""

import base64
import hashlib
import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import boto3
import jwt
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
    load_pem_private_key,
)

PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
SSM_PARAMETER_NAME = os.environ["SNOWFLAKE_PRIVATE_KEY_PARAMETER_NAME"]
ACCOUNT_URL = os.environ["SNOWFLAKE_ACCOUNT_URL"]  # 例: https://<org>-<account>.snowflakecomputing.com
ACCOUNT_IDENTIFIER = os.environ["SNOWFLAKE_ACCOUNT_IDENTIFIER"]  # 例: <ORG>-<ACCOUNT>(大文字)
SNOWFLAKE_USER = os.environ["SNOWFLAKE_USER"]
WAREHOUSE = os.environ["SNOWFLAKE_WAREHOUSE"]
ROLE = os.environ["SNOWFLAKE_ROLE"]

JWT_LIFETIME_SECONDS = 55 * 60  # Snowflakeの推奨上限(1時間)より少し短くしておく
POLL_INTERVAL_SECONDS = 1
MAX_POLL_ATTEMPTS = 30

ssm = boto3.client("ssm")
ec2 = boto3.client("ec2")


def _public_key_fingerprint(private_key) -> str:
    # SnowflakeのJWT認証はiss/subに、公開鍵(X.509 SubjectPublicKeyInfo形式)のSHA256
    # フィンガープリントを含めることを要求する。
    public_key_der = private_key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    digest = hashlib.sha256(public_key_der).digest()
    return "SHA256:" + base64.b64encode(digest).decode("ascii")


def _build_jwt(private_key_pem: str) -> str:
    private_key = load_pem_private_key(private_key_pem.encode(), password=None)
    fingerprint = _public_key_fingerprint(private_key)

    qualified_username = f"{ACCOUNT_IDENTIFIER}.{SNOWFLAKE_USER}"
    now = int(time.time())

    payload = {
        "iss": f"{qualified_username}.{fingerprint}",
        "sub": qualified_username,
        "iat": now,
        "exp": now + JWT_LIFETIME_SECONDS,
    }

    return jwt.encode(payload, private_key, algorithm="RS256")


def _call_sql_api(token):
    body = json.dumps(
        {
            "statement": "SELECT SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES() AS RANGES",
            "warehouse": WAREHOUSE,
            "role": ROLE,
            "timeout": 30,
        }
    ).encode("utf-8")

    headers = {
        "Authorization": f"Bearer {token}",
        "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    req = urllib.request.Request(
        url=f"{ACCOUNT_URL}/api/v2/statements",
        data=body,
        method="POST",
        headers=headers,
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        status = resp.status
        payload = json.loads(resp.read())

    # SQL APIは処理に時間がかかる場合、202とstatementHandleを返し非同期実行になる。
    # このクエリは軽量なため通常は即時応答だが、念のためポーリングに対応しておく。
    attempts = 0
    while status == 202 and attempts < MAX_POLL_ATTEMPTS:
        time.sleep(POLL_INTERVAL_SECONDS)
        handle = payload["statementHandle"]
        poll_req = urllib.request.Request(
            url=f"{ACCOUNT_URL}/api/v2/statements/{handle}",
            method="GET",
            headers=headers,
        )
        with urllib.request.urlopen(poll_req, timeout=30) as resp:
            status = resp.status
            payload = json.loads(resp.read())
        attempts += 1

    if status not in (200, 202):
        raise RuntimeError(f"Snowflake SQL API returned unexpected status {status}: {payload}")

    return payload


def fetch_egress_ip_ranges():
    private_key_pem = ssm.get_parameter(Name=SSM_PARAMETER_NAME, WithDecryption=True)["Parameter"]["Value"]
    token = _build_jwt(private_key_pem)

    try:
        payload = _call_sql_api(token)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Snowflake SQL API request failed: {e.code} {e.read()}") from e

    raw = payload["data"][0][0]
    ranges = json.loads(raw) if isinstance(raw, str) else raw

    now = datetime.now(timezone.utc)
    return {
        entry["ipv4_prefix"]
        for entry in ranges
        if datetime.fromisoformat(entry["expires"].replace("Z", "+00:00")) > now
    }


def sync_security_group(desired_cidrs):
    current = ec2.describe_security_groups(GroupIds=[SECURITY_GROUP_ID])["SecurityGroups"][0]
    current_cidrs = {
        cidr_range["CidrIp"]
        for permission in current["IpPermissions"]
        if permission.get("FromPort") == PORT
        for cidr_range in permission.get("IpRanges", [])
    }

    to_add = desired_cidrs - current_cidrs
    to_remove = current_cidrs - desired_cidrs

    if to_add:
        ec2.authorize_security_group_ingress(
            GroupId=SECURITY_GROUP_ID,
            IpPermissions=[
                {
                    "IpProtocol": "tcp",
                    "FromPort": PORT,
                    "ToPort": PORT,
                    "IpRanges": [{"CidrIp": cidr, "Description": "snowflake-egress-ip"} for cidr in to_add],
                }
            ],
        )
    if to_remove:
        ec2.revoke_security_group_ingress(
            GroupId=SECURITY_GROUP_ID,
            IpPermissions=[
                {
                    "IpProtocol": "tcp",
                    "FromPort": PORT,
                    "ToPort": PORT,
                    "IpRanges": [{"CidrIp": cidr} for cidr in to_remove],
                }
            ],
        )

    return len(to_add), len(to_remove), len(desired_cidrs)


def handler(event, context):
    cidrs = fetch_egress_ip_ranges()
    added, removed, total = sync_security_group(cidrs)
    result = {"added": added, "removed": removed, "total": total}
    print(json.dumps(result))
    return result
