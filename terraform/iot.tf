data "aws_caller_identity" "current" {}

data "aws_iot_endpoint" "current" {
  endpoint_type = "iot:Data-ATS"
}

# デバイス(M5Stack)の書き込み用に Amazon Root CA1 を取得しておく
data "http" "amazon_root_ca1" {
  url = "https://www.amazontrust.com/repository/AmazonRootCA1.pem"
}

resource "local_sensitive_file" "amazon_root_ca1" {
  content  = data.http.amazon_root_ca1.response_body
  filename = "${path.module}/certs/AmazonRootCA1.pem"
}

resource "aws_iot_thing" "env_sensor" {
  name = "${var.project_name}-device"
}

# NOTE: aws_iot_certificate はAWSプロバイダの仕様上importに対応していない。
# 初回構築時にCSRなしで作成した証明書(秘密鍵はAWS側で作成時のみ発行され、以後取得不可)を
# 実機に書き込み済みのため、証明書自体は再発行せずTerraform管理外とし、
# ARNをvar.device_certificate_arnとして固定値参照する。
resource "aws_iot_thing_principal_attachment" "env_sensor" {
  thing     = aws_iot_thing.env_sensor.name
  principal = var.device_certificate_arn
}

# env-sensor.ino では MQTT の clientID が "env-sensor-device" に固定されている
resource "aws_iot_policy" "env_sensor" {
  name = "${var.project_name}-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iot:Connect"
        Resource = "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:client/${var.project_name}-device"
      },
      {
        Effect   = "Allow"
        Action   = "iot:Publish"
        Resource = "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/${var.project_name}/*"
      },
    ]
  })
}

resource "aws_iot_policy_attachment" "env_sensor" {
  policy = aws_iot_policy.env_sensor.name
  target = var.device_certificate_arn
}

# env-sensor.ino がトピック "env-sensor/<chip-id>" に publish したメッセージを Firehose へ転送する
resource "aws_iot_topic_rule" "env_sensor_to_firehose" {
  name        = "${replace(var.project_name, "-", "_")}_to_firehose"
  description = "Forward env-sensor telemetry to Kinesis Data Firehose"
  enabled     = true
  sql         = "SELECT *, timestamp() AS event_timestamp, topic(2) AS device_id FROM '${var.project_name}/#'"
  sql_version = "2016-03-23"

  firehose {
    delivery_stream_name = aws_kinesis_firehose_delivery_stream.env_sensor.name
    role_arn             = aws_iam_role.iot_rule_firehose.arn
  }
}
