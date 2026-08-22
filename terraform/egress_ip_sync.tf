# Snowflake Openflow(Snowflake Deployments/SPCS)の静的Egress IPは90日で失効する。
# RDSのセキュリティグループを手動で追従させ続けるのは現実的でないため、AWS Lambda が週次で
# SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES() をSnowflakeに問い合わせ、RDSのSGへ自動反映する。
#
# 設計方針(漏洩時の被害を小さくするため、Snowflake -> AWS ではなく AWS -> Snowflake の向きにしている):
#   - SGを書き換える権限はLambdaの実行ロール(IAMロール)側だけが持つ。長期のAWSアクセスキーは発行しない。
#   - Snowflake側の認証情報(RSA秘密鍵)は、warehouseのUSAGEしか持たない専用ロールのものに限定する。
#     万一SSMごと漏洩しても、AWSリソースへは波及せず、Snowflakeへの実害のないログインに留まる。
#   - キーペア自体には有効期限がなく(PATと異なり)、失効に伴う定期再発行の運用が不要。

# --- Snowflake: Egress IP取得専用の最小権限ロール・ユーザー ---
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

# AWS LambdaがキーペアJWTでSnowflakeに認証するためのユーザー(firehose.tfと同じパターン)。
resource "tls_private_key" "egress_ip_reader" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

locals {
  egress_ip_reader_public_key_oneline = join("", [
    for line in split("\n", tls_private_key.egress_ip_reader.public_key_pem) :
    line if !startswith(line, "-----") && line != ""
  ])
}

resource "snowflake_service_user" "egress_ip_reader" {
  name              = "IOT_STREAM_EGRESS_IP_READER_USER"
  comment           = "AWS Lambdaがキーペア認証でEgress IPを問い合わせるための最小権限ユーザー"
  rsa_public_key    = local.egress_ip_reader_public_key_oneline
  default_role      = snowflake_account_role.egress_ip_reader.name
  default_warehouse = snowflake_warehouse.openflow_ingest.name
}

resource "snowflake_grant_account_role" "egress_ip_reader_to_user" {
  role_name = snowflake_account_role.egress_ip_reader.name
  user_name = snowflake_service_user.egress_ip_reader.name
}

# --- AWS: 秘密鍵をSecureStringとして保存 ---
resource "aws_ssm_parameter" "egress_ip_reader_private_key" {
  name        = "/${var.project_name}/egress-ip-sync/snowflake-private-key"
  description = "egress_ip_sync LambdaがSnowflakeへキーペア認証するための秘密鍵(PKCS8 PEM)"
  type        = "SecureString"
  value       = tls_private_key.egress_ip_reader.private_key_pem_pkcs8
}

# --- AWS: Lambdaのビルド ---
# cryptography/pyjwtはネイティブ拡張(cryptography)を含むため、ホスト環境に関わらず
# Lambdaランタイム(python3.13, manylinux2014_x86_64)向けのプリビルド済みwheelをpipで取得し、
# Lambda本体と一緒にzip化する。terraform applyを実行する環境にpip(python3)が必要。
resource "null_resource" "egress_ip_sync_build" {
  triggers = {
    source_hash       = filesha256("${path.module}/lambda/egress_ip_sync.py")
    requirements_hash = filesha256("${path.module}/lambda/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      rm -rf "${path.module}/build/egress_ip_sync"
      mkdir -p "${path.module}/build/egress_ip_sync"
      pip install --no-cache-dir \
        --platform manylinux2014_x86_64 --implementation cp --python-version 3.13 --only-binary=:all: \
        --target "${path.module}/build/egress_ip_sync" \
        -r "${path.module}/lambda/requirements.txt"
      cp "${path.module}/lambda/egress_ip_sync.py" "${path.module}/build/egress_ip_sync/"
    EOT
  }
}

data "archive_file" "egress_ip_sync" {
  type        = "zip"
  source_dir  = "${path.module}/build/egress_ip_sync"
  output_path = "${path.module}/build/egress_ip_sync.zip"

  depends_on = [null_resource.egress_ip_sync_build]
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
    resources = [aws_ssm_parameter.egress_ip_reader_private_key.arn]
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
  memory_size      = 256

  environment {
    variables = {
      SECURITY_GROUP_ID                    = aws_security_group.sensor_master.id
      SNOWFLAKE_PRIVATE_KEY_PARAMETER_NAME = aws_ssm_parameter.egress_ip_reader_private_key.name
      SNOWFLAKE_ACCOUNT_URL                = "https://${var.snowflake_organization_name}-${var.snowflake_account_name}.snowflakecomputing.com"
      SNOWFLAKE_ACCOUNT_IDENTIFIER         = upper("${var.snowflake_organization_name}-${var.snowflake_account_name}")
      SNOWFLAKE_USER                       = snowflake_service_user.egress_ip_reader.name
      SNOWFLAKE_WAREHOUSE                  = snowflake_warehouse.openflow_ingest.name
      SNOWFLAKE_ROLE                       = snowflake_account_role.egress_ip_reader.name
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
