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
