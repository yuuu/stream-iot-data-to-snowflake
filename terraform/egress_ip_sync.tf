# Snowflake Openflow(Snowflake Deployments/SPCS)の静的Egress IPは90日で失効する。
# RDSのセキュリティグループを手動で追従させ続けるのは現実的でないため、Snowflake Task が
# SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES() を週次で取得し、boto3経由でRDSのSGへ自動反映する。

# --- AWS: SGのingressだけを更新できる最小権限IAMユーザー ---
resource "aws_iam_user" "sg_updater" {
  name = "${var.project_name}-sg-updater"
}

data "aws_iam_policy_document" "sg_updater" {
  statement {
    effect = "Allow"
    # DescribeSecurityGroupsはリソースレベル権限に対応していないため "*" が必要
    actions   = ["ec2:DescribeSecurityGroups"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
    resources = [aws_security_group.sensor_master.arn]
  }
}

resource "aws_iam_user_policy" "sg_updater" {
  name   = "${var.project_name}-sg-updater-policy"
  user   = aws_iam_user.sg_updater.name
  policy = data.aws_iam_policy_document.sg_updater.json
}

resource "aws_iam_access_key" "sg_updater" {
  user = aws_iam_user.sg_updater.name
}

# --- Snowflake: AWS APIを呼び出すためのSecret / Network Rule / External Access Integration ---
resource "snowflake_secret_with_generic_string" "sg_updater_credentials" {
  database = snowflake_database.iot.name
  schema   = snowflake_schema.sensor_master.name
  name     = "SG_UPDATER_AWS_CREDENTIALS"

  secret_string = jsonencode({
    aws_access_key_id     = aws_iam_access_key.sg_updater.id
    aws_secret_access_key = aws_iam_access_key.sg_updater.secret
    region                = var.aws_region
    security_group_id     = aws_security_group.sensor_master.id
  })

  comment = "egress_ip_sync Task がRDSのSGを更新するためのIAMクレデンシャル"
}

resource "snowflake_network_rule" "ec2_api" {
  database   = snowflake_database.iot.name
  schema     = snowflake_schema.sensor_master.name
  name       = "EC2_API_NETWORK_RULE"
  mode       = "EGRESS"
  type       = "HOST_PORT"
  value_list = ["ec2.${var.aws_region}.amazonaws.com:443"]
  comment    = "egress_ip_sync TaskがEC2 APIを呼び出すための許可"
}

resource "snowflake_execute" "ec2_api_eai" {
  execute = <<-SQL
    CREATE EXTERNAL ACCESS INTEGRATION IOT_STREAM_EC2_API_EAI
      ALLOWED_NETWORK_RULES = (${snowflake_network_rule.ec2_api.fully_qualified_name})
      ALLOWED_AUTHENTICATION_SECRETS = (${snowflake_secret_with_generic_string.sg_updater_credentials.fully_qualified_name})
      ENABLED = TRUE
      COMMENT = 'egress_ip_sync task -> AWS EC2 API'
  SQL

  revert = "DROP EXTERNAL ACCESS INTEGRATION IOT_STREAM_EC2_API_EAI"
}

# --- Snowflake: Egress IPを取得してRDSのSGへ反映するStored Procedure ---
resource "snowflake_procedure_python" "sync_egress_ip" {
  database        = snowflake_database.iot.name
  schema          = snowflake_schema.sensor_master.name
  name            = "SYNC_RDS_SECURITY_GROUP_WITH_EGRESS_IP"
  return_type     = "STRING"
  handler         = "main"
  runtime_version = "3.11"
  # Snowsight「パッケージ」一覧に表示される最新バージョンに適宜合わせること。
  snowpark_package = "1.23.0"
  packages         = ["boto3"]

  # snowflake_external_access_integrationリソースが存在しないため名前を直接指定する(snowflake_execute.ec2_api_eaiが作成)。
  external_access_integrations = ["IOT_STREAM_EC2_API_EAI"]

  secrets {
    secret_id            = snowflake_secret_with_generic_string.sg_updater_credentials.fully_qualified_name
    secret_variable_name = "sg_updater_credentials"
  }

  procedure_definition = <<-PYTHON
    import json
    from datetime import datetime, timezone

    import _snowflake
    import boto3

    PORT = 5432


    def main(session):
        creds = json.loads(_snowflake.get_generic_secret_string("sg_updater_credentials"))

        raw = session.sql(
            "SELECT SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES() AS ranges"
        ).collect()[0]["RANGES"]
        ranges = json.loads(raw) if isinstance(raw, str) else raw

        now = datetime.now(timezone.utc)
        cidrs = {
            entry["ipv4_prefix"]
            for entry in ranges
            if datetime.fromisoformat(entry["expires"].replace("Z", "+00:00")) > now
        }

        ec2 = boto3.client(
            "ec2",
            region_name=creds["region"],
            aws_access_key_id=creds["aws_access_key_id"],
            aws_secret_access_key=creds["aws_secret_access_key"],
        )
        sg_id = creds["security_group_id"]

        current = ec2.describe_security_groups(GroupIds=[sg_id])["SecurityGroups"][0]
        current_cidrs = {
            r["CidrIp"]
            for permission in current["IpPermissions"]
            if permission.get("FromPort") == PORT
            for r in permission.get("IpRanges", [])
        }

        to_add = cidrs - current_cidrs
        to_remove = current_cidrs - cidrs

        if to_add:
            ec2.authorize_security_group_ingress(
                GroupId=sg_id,
                IpPermissions=[{
                    "IpProtocol": "tcp",
                    "FromPort": PORT,
                    "ToPort": PORT,
                    "IpRanges": [
                        {"CidrIp": cidr, "Description": "snowflake-egress-ip"}
                        for cidr in to_add
                    ],
                }],
            )
        if to_remove:
            ec2.revoke_security_group_ingress(
                GroupId=sg_id,
                IpPermissions=[{
                    "IpProtocol": "tcp",
                    "FromPort": PORT,
                    "ToPort": PORT,
                    "IpRanges": [{"CidrIp": cidr} for cidr in to_remove],
                }],
            )

        return f"added={len(to_add)} removed={len(to_remove)} total={len(cidrs)}"
  PYTHON

  comment = "SnowflakeのEgress IPをRDSセキュリティグループへ同期する"

  depends_on = [snowflake_execute.ec2_api_eai]
}

resource "snowflake_task" "sync_egress_ip" {
  database  = snowflake_database.iot.name
  schema    = snowflake_schema.sensor_master.name
  name      = "SYNC_RDS_SECURITY_GROUP_WITH_EGRESS_IP_TASK"
  warehouse = snowflake_warehouse.openflow_ingest.name

  schedule {
    using_cron = "0 0 * * MON UTC"
  }

  sql_statement = "CALL ${snowflake_procedure_python.sync_egress_ip.fully_qualified_name}()"
  started       = true

  comment = "Egress IPを週次でRDSのSGへ同期するTask"
}
