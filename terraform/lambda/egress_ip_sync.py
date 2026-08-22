"""
SnowflakeのEgress IP(SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES())を取得し、
RDS(sensor_master)のセキュリティグループのingressルールへ同期するLambda。

Snowflake認証にはProgrammatic Access Token(PAT)を使う。PAT自体はSSM Parameter Store
(SecureString)に保存されており、このLambdaはSnowflakeへの読み取り専用アクセスしか
持たない(SGを書き換える権限はLambdaの実行ロール側にのみ存在する)。

標準ライブラリ + boto3(Lambdaランタイムに標準同梱)のみで動作し、追加パッケージの
インストール・レイヤーは不要。
"""

import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import boto3

PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
SSM_PARAMETER_NAME = os.environ["SNOWFLAKE_PAT_PARAMETER_NAME"]
ACCOUNT_URL = os.environ["SNOWFLAKE_ACCOUNT_URL"]  # 例: https://<org>-<account>.snowflakecomputing.com
WAREHOUSE = os.environ["SNOWFLAKE_WAREHOUSE"]
ROLE = os.environ["SNOWFLAKE_ROLE"]

POLL_INTERVAL_SECONDS = 1
MAX_POLL_ATTEMPTS = 30

ssm = boto3.client("ssm")
ec2 = boto3.client("ec2")


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
        "X-Snowflake-Authorization-Token-Type": "PROGRAMMATIC_ACCESS_TOKEN",
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
    token = ssm.get_parameter(Name=SSM_PARAMETER_NAME, WithDecryption=True)["Parameter"]["Value"]

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
