output "iot_endpoint" {
  description = "デバイスから接続するAWS IoT Coreのエンドポイント"
  value       = data.aws_iot_endpoint.current.endpoint_address
}

output "iot_thing_name" {
  value = aws_iot_thing.env_sensor.name
}

output "firehose_delivery_stream_name" {
  value = aws_kinesis_firehose_delivery_stream.env_sensor.name
}

output "firehose_backup_bucket" {
  value = aws_s3_bucket.firehose_backup.bucket
}

output "snowflake_table" {
  value = local.env_sensor_table_fqn
}

output "device_certs_dir" {
  description = "arduino_secrets.h に転記する証明書・秘密鍵の出力先"
  value       = "${path.module}/certs"
}
