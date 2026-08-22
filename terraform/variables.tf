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

variable "snowflake_organization_name" {
  description = "Snowflake organization name (see CURRENT_ORGANIZATION_NAME())"
  type        = string
}

variable "snowflake_account_name" {
  description = "Snowflake account name (see CURRENT_ACCOUNT_NAME())"
  type        = string
}

variable "snowflake_admin_user" {
  description = "Snowflake service user Terraform authenticates as (key-pair auth)"
  type        = string
}

variable "snowflake_admin_private_key_path" {
  description = "Path to the unencrypted PKCS8 private key (PEM) file for snowflake_admin_user"
  type        = string
}

variable "device_certificate_arn" {
  description = "ARN of the existing AWS IoT certificate attached to the device (created outside Terraform; see README)"
  type        = string
}

variable "rds_allowed_cidr_blocks" {
  description = <<-EOT
    CIDR blocks allowed to reach the RDS PostgreSQL instance on port 5432.
    Seed this with the output of `SELECT SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES();` (run once, before the first apply)
    plus your own IP for manual psql access. After the first apply, the egress_ip_sync.tf Lambda (scheduled weekly)
    keeps the security group in sync automatically (see README), so this variable only matters for the initial
    bootstrap.
  EOT
  type        = list(string)
}

variable "rds_instance_class" {
  description = "RDS instance class for the sensor master PostgreSQL database"
  type        = string
  default     = "db.t4g.micro"
}

variable "postgres_master_username" {
  description = "Master username for the RDS PostgreSQL instance"
  type        = string
  default     = "postgres_admin"
}

variable "sensors_db_name" {
  description = "Initial database name created on the RDS PostgreSQL instance"
  type        = string
  default     = "sensors"
}
