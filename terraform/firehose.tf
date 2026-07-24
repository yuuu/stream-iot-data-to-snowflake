resource "random_id" "firehose_backup_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "firehose_backup" {
  bucket = "${var.project_name}-firehose-backup-${random_id.firehose_backup_bucket_suffix.hex}"
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.project_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "firehose_snowflake" {
  name           = "SnowflakeDelivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

# Firehose が S3(バックアップ)・CloudWatch Logs にアクセスするためのロール
# NOTE: Snowflakeへの接続自体はこのIAMロールを経由せず、user + private_key のキーペア認証で行われる
data "aws_iam_policy_document" "firehose_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.project_name}-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json
}

data "aws_iam_policy_document" "firehose_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.firehose_backup.arn,
      "${aws_s3_bucket.firehose_backup.arn}/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "${var.project_name}-firehose-policy"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose_permissions.json
}

# IoT Topic Rule が Firehose へ PutRecord するためのロール
data "aws_iam_policy_document" "iot_rule_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["iot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "iot_rule_firehose" {
  name               = "${var.project_name}-iot-rule-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.iot_rule_assume_role.json
}

data "aws_iam_policy_document" "iot_rule_firehose_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
    resources = [aws_kinesis_firehose_delivery_stream.env_sensor.arn]
  }
}

resource "aws_iam_role_policy" "iot_rule_firehose" {
  name   = "${var.project_name}-iot-rule-firehose-policy"
  role   = aws_iam_role.iot_rule_firehose.id
  policy = data.aws_iam_policy_document.iot_rule_firehose_permissions.json
}

resource "aws_kinesis_firehose_delivery_stream" "env_sensor" {
  name        = "${var.project_name}-to-snowflake"
  destination = "snowflake"

  snowflake_configuration {
    account_url = "https://${var.snowflake_organization_name}-${var.snowflake_account_name}.snowflakecomputing.com"

    user        = snowflake_service_user.firehose_ingest.name
    private_key = local.firehose_private_key_oneline

    database = snowflake_database.iot.name
    schema   = snowflake_schema.env_sensor.name
    table    = "ENV_SENSOR_RAW"

    data_loading_option = "JSON_MAPPING"

    role_arn = aws_iam_role.firehose.arn

    s3_configuration {
      role_arn   = aws_iam_role.firehose.arn
      bucket_arn = aws_s3_bucket.firehose_backup.arn
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_snowflake.name
    }
  }
}
