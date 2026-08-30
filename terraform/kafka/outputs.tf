output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "MSK ブローカー / IoT VPC destination / MSK Connect 用のプライベートサブネット"
  value       = aws_subnet.private[*].id
}

output "msk_cluster_arn" {
  value = aws_msk_cluster.this.arn
}

output "msk_bootstrap_brokers_sasl_scram" {
  description = "SASL/SCRAM (9096/TLS) のブートストラップブローカー"
  value       = aws_msk_cluster.this.bootstrap_brokers_sasl_scram
}

output "msk_zookeeper_connect_string" {
  value = aws_msk_cluster.this.zookeeper_connect_string
}

output "msk_security_group_id" {
  value = aws_security_group.msk.id
}

output "scram_secret_arns" {
  description = "コンポーネント別 SASL/SCRAM 認証情報 (Secrets Manager)"
  value       = { for u, s in aws_secretsmanager_secret.scram : u => s.arn }
}

output "scram_kms_key_arn" {
  value = aws_kms_key.scram.arn
}

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "bastion_public_dns" {
  value = aws_instance.bastion.public_dns
}

output "bastion_ssh_key_path" {
  value = local_sensitive_file.bastion_private_key.filename
}

output "bastion_ssh_command" {
  description = "踏み台への基本 SSH コマンド (ブローカー確定後に -L でトンネルを足す)"
  value       = "ssh -i ${local_sensitive_file.bastion_private_key.filename} ec2-user@${aws_instance.bastion.public_ip}"
}

output "iot_data_endpoint" {
  description = "aws iot-data publish の --endpoint-url に使う"
  value       = "https://${data.aws_iot_endpoint.data_ats.endpoint_address}"
}

output "iot_kafka_rule_name" {
  value = aws_iot_topic_rule.env_sensor_to_kafka.name
}

output "iot_kafka_error_log_group" {
  value = aws_cloudwatch_log_group.iot_kafka_errors.name
}

output "iot_kafka_destination_arn" {
  value = aws_iot_topic_rule_destination.kafka.arn
}

output "msk_bootstrap_brokers_sasl_iam" {
  description = "IAM 認証 (9098/TLS) のブートストラップブローカー (MSK Connect 用)"
  value       = aws_msk_cluster.this.bootstrap_brokers_sasl_iam
}

output "msk_connect_connector_arn" {
  value = aws_mskconnect_connector.snowflake.arn
}

output "msk_connect_log_group" {
  value = aws_cloudwatch_log_group.msk_connect.name
}

output "snowflake_kafka_table_fqn" {
  description = "Snowflake Kafka Connector の書き込み先テーブル"
  value       = local.sf_kafka_table_fqn
}

output "snowflake_kafka_connect_user" {
  value = snowflake_service_user.kafka_connect.name
}
