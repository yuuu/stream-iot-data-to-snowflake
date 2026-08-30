variable "aws_profile" {
  description = "AWS CLI profile used to authenticate. Set in terraform.tfvars (gitignored)."
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Prefix used when naming resources"
  type        = string
  default     = "env-sensor"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated Kafka verification VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread the 3 MSK broker subnets across (must be 3 for number_of_broker_nodes = 3)"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
}

variable "ssh_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to SSH into the bastion host (work terminal global IPs). Set in terraform.tfvars."
  type        = list(string)
}

variable "kafka_version" {
  description = "MSK Kafka version (rolling identifier, e.g. 3.8.x)"
  type        = string
  default     = "3.8.x"
}

variable "broker_instance_type" {
  description = "MSK broker instance type"
  type        = string
  default     = "kafka.t3.small"
}

variable "broker_ebs_volume_size" {
  description = "EBS volume size (GiB) per MSK broker"
  type        = number
  default     = 10
}

variable "scram_users" {
  # admin      : 検証用 CLI(踏み台)
  # iot-ingest : IoT Rule Kafka Action(IAM 非対応のため SASL/SCRAM)
  # karafka    : Karafka コンシューマ(ローカル + SSH ポートフォワード)
  # msk-connect: 【未使用】MSK Connect は SASL/SCRAM 実質不可のため IAM 認証に変更した。
  #             シークレット等はコード上残置(フェーズ4で削除要否を判断)。経緯は WORK_NOTES_kafka.md 参照。
  description = "SASL/SCRAM usernames to provision (one Secrets Manager secret each), split per pipeline component"
  type        = list(string)
  default     = ["admin", "iot-ingest", "msk-connect", "karafka"]
}

# --- フェーズ2-c: Snowflake / MSK Connect ---

variable "snowflake_organization_name" {
  description = "Snowflake organization name (CURRENT_ORGANIZATION_NAME())"
  type        = string
}

variable "snowflake_account_name" {
  description = "Snowflake account name (CURRENT_ACCOUNT_NAME())"
  type        = string
}

variable "snowflake_admin_user" {
  description = "Snowflake service user Terraform authenticates as (key-pair auth)"
  type        = string
}

variable "snowflake_admin_private_key_path" {
  description = "Path to the unencrypted PKCS8 private key (PEM) for snowflake_admin_user"
  type        = string
}

variable "snowflake_kafka_connector_version" {
  description = "Snowflake Kafka Connector version to fetch from Maven Central for the MSK Connect custom plugin"
  type        = string
  default     = "3.2.2"
}

variable "msk_connect_kafkaconnect_version" {
  description = "Apache Kafka Connect version for the MSK Connect connector"
  type        = string
  default     = "2.7.1"
}
