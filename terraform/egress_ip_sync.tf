# Snowflake Openflow(Snowflake Deployments/SPCS)の静的Egress IPは90日で失効する。
# RDSのセキュリティグループを手動で追従させ続けるのは現実的でないため、AWS Lambda が週次で
# SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES() をSnowflakeに問い合わせ、RDSのSGへ自動反映する。
#
# 設計方針(漏洩時の被害を小さくするため、Snowflake -> AWS ではなく AWS -> Snowflake の向きにしている):
#   - SGを書き換える権限はLambdaの実行ロール(IAMロール)側だけが持つ。長期のAWSアクセスキーは発行しない。
#   - Snowflake側に置く認証情報(PAT)は、warehouseのUSAGEしか持たない専用ロールのものに限定する。
#     万一SSMごと漏洩しても、AWSリソースへは波及せず、Snowflakeへの実害のないログインに留まる。

# --- Snowflake: Egress IP取得専用の最小権限ロール・ユーザー・PAT ---
resource "snowflake_account_role" "egress_ip_reader" {
  name    = "IOT_STREAM_EGRESS_IP_READER_ROLE"
  comment = "SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES()の呼び出しのみを目的とした最小権限ロール"
}

# SQL API経由でのクエリ実行にwarehouseが必要なため、USAGEのみ付与する(データへのアクセス権は一切なし)。
resource "snowflake_grant_privileges_to_account_role" "egress_ip_reader_warehouse" {
  account_role_name = snowflake_account_role.egress_ip_reader.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.openflow_ingest.name
  }
}

resource "snowflake_service_user" "egress_ip_reader" {
  name              = "IOT_STREAM_EGRESS_IP_READER_USER"
  comment           = "AWS LambdaがPATでEgress IPを問い合わせるための最小権限ユーザー"
  default_role      = snowflake_account_role.egress_ip_reader.name
  default_warehouse = snowflake_warehouse.openflow_ingest.name
}

resource "snowflake_grant_account_role" "egress_ip_reader_to_user" {
  role_name = snowflake_account_role.egress_ip_reader.name
  user_name = snowflake_service_user.egress_ip_reader.name
}

resource "snowflake_user_programmatic_access_token" "egress_ip_reader" {
  user             = snowflake_service_user.egress_ip_reader.name
  name             = "EGRESS_IP_SYNC_LAMBDA"
  role_restriction = snowflake_account_role.egress_ip_reader.name
  days_to_expiry   = 365
  comment          = "egress_ip_sync Lambda用。失効時はterraform apply -replaceで再発行しSSMへ反映すること"

  depends_on = [snowflake_grant_account_role.egress_ip_reader_to_user]
}

# --- AWS: PATをSecureStringとして保存 ---
resource "aws_ssm_parameter" "snowflake_egress_ip_reader_pat" {
  name        = "/${var.project_name}/egress-ip-sync/snowflake-pat"
  description = "egress_ip_sync LambdaがSnowflakeへ認証するためのProgrammatic Access Token"
  type        = "SecureString"
  value       = snowflake_user_programmatic_access_token.egress_ip_reader.token
}

# --- AWS: Lambda本体 ---
data "archive_file" "egress_ip_sync" {
  type        = "zip"
  source_file = "${path.module}/lambda/egress_ip_sync.py"
  output_path = "${path.module}/build/egress_ip_sync.zip"
}

data "aws_iam_policy_document" "egress_ip_sync_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "egress_ip_sync" {
  name               = "${var.project_name}-egress-ip-sync"
  assume_role_policy = data.aws_iam_policy_document.egress_ip_sync_assume_role.json
}

resource "aws_iam_role_policy_attachment" "egress_ip_sync_logs" {
  role       = aws_iam_role.egress_ip_sync.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "egress_ip_sync" {
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

  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.snowflake_egress_ip_reader_pat.arn]
  }
}

resource "aws_iam_role_policy" "egress_ip_sync" {
  name   = "${var.project_name}-egress-ip-sync-policy"
  role   = aws_iam_role.egress_ip_sync.id
  policy = data.aws_iam_policy_document.egress_ip_sync.json
}

resource "aws_lambda_function" "egress_ip_sync" {
  function_name = "${var.project_name}-egress-ip-sync"
  role          = aws_iam_role.egress_ip_sync.arn

  filename         = data.archive_file.egress_ip_sync.output_path
  source_code_hash = data.archive_file.egress_ip_sync.output_base64sha256
  handler          = "egress_ip_sync.handler"
  runtime          = "python3.13"
  timeout          = 60

  environment {
    variables = {
      SECURITY_GROUP_ID            = aws_security_group.sensor_master.id
      SNOWFLAKE_PAT_PARAMETER_NAME = aws_ssm_parameter.snowflake_egress_ip_reader_pat.name
      SNOWFLAKE_ACCOUNT_URL        = "https://${var.snowflake_organization_name}-${var.snowflake_account_name}.snowflakecomputing.com"
      SNOWFLAKE_WAREHOUSE          = snowflake_warehouse.openflow_ingest.name
      SNOWFLAKE_ROLE               = snowflake_account_role.egress_ip_reader.name
    }
  }
}

# --- AWS: 週次実行のスケジュール ---
resource "aws_cloudwatch_event_rule" "egress_ip_sync_weekly" {
  name                = "${var.project_name}-egress-ip-sync-weekly"
  description         = "Snowflakeの静的Egress IPをRDSのSGへ週次で同期する"
  schedule_expression = "cron(0 0 ? * MON *)"
}

resource "aws_cloudwatch_event_target" "egress_ip_sync" {
  rule = aws_cloudwatch_event_rule.egress_ip_sync_weekly.name
  arn  = aws_lambda_function.egress_ip_sync.arn
}

resource "aws_lambda_permission" "egress_ip_sync_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.egress_ip_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.egress_ip_sync_weekly.arn
}
