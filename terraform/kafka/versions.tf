terraform {
  required_version = ">= 1.15.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.18"
    }
  }
}
