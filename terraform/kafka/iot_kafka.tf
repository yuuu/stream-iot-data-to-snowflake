############################################
# フェーズ2-b: IoT Rule の Kafka Action (VPC destination)
#
# AWS IoT Core が受信した env-sensor/<device-id> 宛メッセージを、
# VPC 内の MSK トピック env-sensor-telemetry へ直接 produce する。
# 認証は SASL_SSL / SCRAM-SHA-512、認証情報は Secrets Manager の
# AmazonMSK_env-sensor_iot-ingest から get_secret() で解決する。
############################################

data "aws_iot_endpoint" "data_ats" {
  endpoint_type = "iot:Data-ATS"
}

# --- IoT ルールが VPC destination の ENI 管理 / Secrets Manager 読取 / エラーログ出力に使う IAM ロール ---
data "aws_iam_policy_document" "iot_kafka_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["iot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "iot_kafka_rule" {
  name               = "${var.project_name}-kafka-iot-rule-role"
  assume_role_policy = data.aws_iam_policy_document.iot_kafka_assume_role.json
}

data "aws_iam_policy_document" "iot_kafka_rule" {
  # VPC destination の ENI 作成/削除 (AWS ドキュメント apache-kafka-rule-action.html の要件)
  statement {
    sid    = "ManageVpcEni"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:CreateNetworkInterfacePermission",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeSecurityGroups",
    ]
    resources = ["*"]
  }

  # get_secret() で iot-ingest の SCRAM 認証情報を取得
  statement {
    sid       = "ReadIotIngestSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.scram["iot-ingest"].arn]
  }

  statement {
    sid       = "DecryptScramSecret"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.scram.arn]
  }

  # ルール実行エラーを CloudWatch Logs へ
  statement {
    sid    = "WriteRuleErrorLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.iot_kafka_errors.arn}:*"]
  }
}

resource "aws_iam_role_policy" "iot_kafka_rule" {
  name   = "${var.project_name}-kafka-iot-rule-policy"
  role   = aws_iam_role.iot_kafka_rule.id
  policy = data.aws_iam_policy_document.iot_kafka_rule.json
}

# --- IoT ルールエンジンが MSK 到達用の ENI を張るサブネット/SG ---
resource "aws_security_group" "iot_kafka" {
  name        = "${var.project_name}-kafka-iot-eni-sg"
  description = "ENIs created by the AWS IoT rules engine to reach MSK"
  vpc_id      = aws_vpc.this.id

  # MSK ブローカー(SASL_SCRAM 9096)への egress。MSK 側 SG は VPC CIDR から 9092-9098 を許可済み。
  egress {
    description = "to MSK brokers"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-kafka-iot-eni-sg" }
}

resource "aws_iot_topic_rule_destination" "kafka" {
  vpc_configuration {
    vpc_id          = aws_vpc.this.id
    subnet_ids      = aws_subnet.private[*].id
    security_groups = [aws_security_group.iot_kafka.id]
    role_arn        = aws_iam_role.iot_kafka_rule.arn
  }

  depends_on = [aws_iam_role_policy.iot_kafka_rule]
}

# --- ルール実行エラーの受け皿 ---
resource "aws_cloudwatch_log_group" "iot_kafka_errors" {
  name              = "/aws/iot/${var.project_name}-kafka-rule-errors"
  retention_in_days = 14
}

# --- Kafka Action 付き Topic Rule ---
# 前回記事の env_sensor_to_firehose と同じ SQL。両ルールが同一トピックで併存し、
# 1 回の publish が Firehose と Kafka の両方に配信される(フェーズ3 のファンアウト実演に流用可)。
resource "aws_iot_topic_rule" "env_sensor_to_kafka" {
  name        = "${replace(var.project_name, "-", "_")}_to_kafka"
  description = "Forward env-sensor telemetry to Amazon MSK (Kafka) via VPC destination"
  enabled     = true
  sql         = "SELECT *, timestamp() AS event_timestamp, topic(2) AS device_id FROM '${var.project_name}/#'"
  sql_version = "2016-03-23"

  kafka {
    destination_arn = aws_iot_topic_rule_destination.kafka.arn
    topic           = "env-sensor-telemetry"

    # device_id(MQTT トピックの 2 セグメント目)をメッセージキーにして
    # 同一デバイスのメッセージを同一パーティションへ固定する
    key = "$${topic(2)}"

    client_properties = {
      "bootstrap.servers"   = aws_msk_cluster.this.bootstrap_brokers_sasl_scram
      "security.protocol"   = "SASL_SSL"
      "sasl.mechanism"      = "SCRAM-SHA-512"
      "sasl.scram.username" = "$${get_secret('${aws_secretsmanager_secret.scram["iot-ingest"].arn}', 'SecretString', 'username', '${aws_iam_role.iot_kafka_rule.arn}')}"
      "sasl.scram.password" = "$${get_secret('${aws_secretsmanager_secret.scram["iot-ingest"].arn}', 'SecretString', 'password', '${aws_iam_role.iot_kafka_rule.arn}')}"
      "key.serializer"      = "org.apache.kafka.common.serialization.StringSerializer"
      "value.serializer"    = "org.apache.kafka.common.serialization.ByteBufferSerializer"
      "acks"                = "1"
    }
  }

  error_action {
    cloudwatch_logs {
      log_group_name = aws_cloudwatch_log_group.iot_kafka_errors.name
      role_arn       = aws_iam_role.iot_kafka_rule.arn
    }
  }
}
