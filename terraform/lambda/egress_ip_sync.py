"""
SnowflakeのEgress IP(SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES())を取得し、
RDS(sensor_master)のセキュリティグループのingressルールへ同期するLambda。

Snowflake認証にはキーペア(RSA)を使う。秘密鍵はSSM Parameter Store(SecureString)に
保存されており、このLambdaはSnowflakeへの読み取り専用アクセスしか持たない
(SGを書き換える権限はLambdaの実行ロール側にのみ存在する)。

JWTの構築・SQL実行は公式のsnowflake-connector-pythonに委譲する。boto3/botocore/
s3transfer/jmespathはLambdaランタイムに標準同梱されているため、ビルド時に
パッケージから除外している(egress_ip_sync.tf, requirements.txt参照)。
"""

import json
import os
from datetime import datetime, timezone

import boto3
import snowflake.connector
from cryptography.hazmat.primitives.serialization import load_pem_private_key

PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
SSM_PARAMETER_NAME = os.environ["SNOWFLAKE_PRIVATE_KEY_PARAMETER_NAME"]
SNOWFLAKE_ACCOUNT = os.environ["SNOWFLAKE_ACCOUNT"]  # 例: <org>-<account>
SNOWFLAKE_USER = os.environ["SNOWFLAKE_USER"]
WAREHOUSE = os.environ["SNOWFLAKE_WAREHOUSE"]
ROLE = os.environ["SNOWFLAKE_ROLE"]

ssm = boto3.client("ssm")
ec2 = boto3.client("ec2")


def fetch_egress_ip_ranges():
    private_key_pem = ssm.get_parameter(Name=SSM_PARAMETER_NAME, WithDecryption=True)["Parameter"]["Value"]
    private_key = load_pem_private_key(private_key_pem.encode(), password=None)

    conn = snowflake.connector.connect(
        account=SNOWFLAKE_ACCOUNT,
        user=SNOWFLAKE_USER,
        private_key=private_key,
        warehouse=WAREHOUSE,
        role=ROLE,
    )
    try:
        cur = conn.cursor()
        cur.execute("SELECT SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES() AS RANGES")
        raw = cur.fetchone()[0]
    finally:
        conn.close()

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
