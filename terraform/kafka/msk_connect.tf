############################################
# フェーズ2-c: MSK Connect + Snowflake Kafka Connector(Snowpipe Streaming)
#
# MSK への接続は IAM 認証(MSK Connect は SASL/SCRAM が実質不可のため)。
# 経緯・認証方式対応表は WORK_NOTES_kafka.md 参照。
############################################

# --- カスタムプラグイン用 S3 バケット ---
resource "random_id" "plugin_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "msk_connect_plugin" {
  bucket        = "${var.project_name}-kafka-mskconnect-plugin-${random_id.plugin_bucket_suffix.hex}"
  force_destroy = true
}

# Snowflake Kafka Connector の jar を Maven Central から取得(fat jar。暗号化なし秘密鍵なら追加依存不要)
resource "terraform_data" "download_connector" {
  triggers_replace = [var.snowflake_kafka_connector_version]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      mkdir -p '${path.module}/build'
      f='${path.module}/build/snowflake-kafka-connector-${var.snowflake_kafka_connector_version}.jar'
      if [ ! -s "$f" ]; then
        curl -fsSL -o "$f" \
          'https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/${var.snowflake_kafka_connector_version}/snowflake-kafka-connector-${var.snowflake_kafka_connector_version}.jar'
      fi
    EOT
  }
}

resource "aws_s3_object" "connector_plugin" {
  bucket = aws_s3_bucket.msk_connect_plugin.id
  key    = "snowflake-kafka-connector-${var.snowflake_kafka_connector_version}.jar"
  source = "${path.module}/build/snowflake-kafka-connector-${var.snowflake_kafka_connector_version}.jar"

  depends_on = [terraform_data.download_connector]
}

resource "aws_mskconnect_custom_plugin" "snowflake" {
  name         = "${var.project_name}-snowflake-kafka-connector"
  content_type = "JAR"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.msk_connect_plugin.arn
      file_key   = aws_s3_object.connector_plugin.key
    }
  }
}

# --- コネクタ実行ロール(IAM 認証で MSK へ接続) ---
data "aws_iam_policy_document" "msk_connect_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["kafkaconnect.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "msk_connect" {
  name               = "${var.project_name}-kafka-mskconnect-role"
  assume_role_policy = data.aws_iam_policy_document.msk_connect_assume.json
}

locals {
  msk_cluster_uuid  = element(split("/", aws_msk_cluster.this.arn), length(split("/", aws_msk_cluster.this.arn)) - 1)
  msk_topic_arn_pfx = "arn:aws:kafka:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/${aws_msk_cluster.this.cluster_name}/${local.msk_cluster_uuid}"
  msk_group_arn_pfx = "arn:aws:kafka:${var.aws_region}:${data.aws_caller_identity.current.account_id}:group/${aws_msk_cluster.this.cluster_name}/${local.msk_cluster_uuid}"
}

data "aws_iam_policy_document" "msk_connect" {
  statement {
    sid       = "ClusterConnect"
    effect    = "Allow"
    actions   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster", "kafka-cluster:DescribeClusterDynamicConfiguration"]
    resources = [aws_msk_cluster.this.arn]
  }

  statement {
    sid    = "TopicReadWrite"
    effect = "Allow"
    actions = [
      "kafka-cluster:CreateTopic",
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:DescribeTopicDynamicConfiguration",
      "kafka-cluster:ReadData",
      "kafka-cluster:WriteData",
      "kafka-cluster:AlterTopicDynamicConfiguration",
    ]
    # env-sensor-telemetry と、MSK Connect が内部で使う __amazon_msk_connect_* トピック
    resources = ["${local.msk_topic_arn_pfx}/*"]
  }

  statement {
    sid       = "GroupAccess"
    effect    = "Allow"
    actions   = ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"]
    resources = ["${local.msk_group_arn_pfx}/*"]
  }

  statement {
    sid       = "PluginFromS3"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.msk_connect_plugin.arn}/*"]
  }

  statement {
    sid    = "ConnectorLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.msk_connect.arn}:*"]
  }
}

resource "aws_iam_role_policy" "msk_connect" {
  name   = "${var.project_name}-kafka-mskconnect-policy"
  role   = aws_iam_role.msk_connect.id
  policy = data.aws_iam_policy_document.msk_connect.json
}

# --- コネクタが MSK へ ENI で接続する SG ---
resource "aws_security_group" "msk_connect" {
  name        = "${var.project_name}-kafka-mskconnect-sg"
  description = "MSK Connect connector ENIs (egress to MSK 9098/IAM and Snowflake 443 via NAT)"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-kafka-mskconnect-sg" }
}

resource "aws_cloudwatch_log_group" "msk_connect" {
  name              = "/aws/mskconnect/${var.project_name}-snowflake-env-sensor-sink"
  retention_in_days = 14
}

resource "aws_mskconnect_connector" "snowflake" {
  name                 = "snowflake-env-sensor-sink"
  kafkaconnect_version = var.msk_connect_kafkaconnect_version

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    "connector.class" = "com.snowflake.kafka.connector.SnowflakeSinkConnector"
    "tasks.max"       = "1"
    "topics"          = "env-sensor-telemetry"

    "snowflake.url.name"      = "${lower(var.snowflake_organization_name)}-${lower(var.snowflake_account_name)}.snowflakecomputing.com:443"
    "snowflake.user.name"     = snowflake_service_user.kafka_connect.name
    "snowflake.role.name"     = snowflake_account_role.kafka_connect.name
    "snowflake.private.key"   = local.kc_private_key_oneline
    "snowflake.database.name" = snowflake_database.kafka.name
    "snowflake.schema.name"   = snowflake_schema.env_sensor_kafka.name

    "snowflake.ingestion.method" = "SNOWPIPE_STREAMING"
    # schematization=true: 受信 JSON のキーを ENV_SENSOR_RAW の型付きカラム
    # (TEMPERATURE / HUMIDITY / PRESSURE / EVENT_TIMESTAMP / DEVICE_ID)へマッピングする。
    # テーブルは snowflake_kafka.tf で明示作成済みなので、Connector は既存カラムに INSERT するだけ
    # (カラムが一致しているのでスキーマ進化 ALTER は発生しない)。
    # ※ false にすると RECORD_METADATA + RECORD_CONTENT(VARIANT 1本)になり型付きカラムに入らないため true のまま。
    "snowflake.enable.schematization"    = "true"
    "snowflake.streaming.max.client.lag" = "1"
    "snowflake.topic2table.map"          = "env-sensor-telemetry:${local.sf_kafka_table_name}"

    "key.converter"                  = "org.apache.kafka.connect.storage.StringConverter"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter.schemas.enable" = "false"

    "errors.tolerance"  = "all"
    "errors.log.enable" = "true"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = aws_msk_cluster.this.bootstrap_brokers_sasl_iam

      vpc {
        security_groups = [aws_security_group.msk_connect.id]
        subnets         = aws_subnet.private[*].id
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.snowflake.arn
      revision = aws_mskconnect_custom_plugin.snowflake.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.msk_connect.arn

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_connect.name
      }
    }
  }

  depends_on = [
    aws_iam_role_policy.msk_connect,
    aws_route.private_default,
    aws_nat_gateway.this,
    snowflake_grant_privileges_to_account_role.kc_database,
    snowflake_grant_privileges_to_account_role.kc_schema,
    snowflake_grant_privileges_to_account_role.kc_table,
    snowflake_grant_account_role.kc_to_user,
    snowflake_execute.env_sensor_raw_table,
  ]
}
