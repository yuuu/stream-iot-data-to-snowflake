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

output "snowflake_hourly_avg_table" {
  value = local.env_sensor_hourly_avg_table_fqn
}

output "device_certs_dir" {
  description = "arduino_secrets.h に転記する証明書・秘密鍵の出力先"
  value       = "${path.module}/certs"
}

output "rds_endpoint" {
  description = "RDS PostgreSQLインスタンスの接続エンドポイント(ホスト名)"
  value       = aws_db_instance.sensor_master.address
}

output "rds_master_password" {
  description = "RDSマスターユーザーのパスワード(terraform output -raw rds_master_password で取得)"
  value       = random_password.sensor_master.result
  sensitive   = true
}

output "snowflake_sensor_master_table" {
  description = "Openflow Connector for PostgreSQLが作成する取り込み先テーブル(初回スナップショット完了後に存在)"
  value       = local.sensor_master_table_fqn
}

output "snowflake_hourly_avg_enriched_table" {
  description = "センサー値とマスターデータをJOINしたDynamic Table"
  value       = local.env_sensor_hourly_avg_enriched_table_fqn
}
