provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.project_name
      Component = "kafka-msk-streaming"
      ManagedBy = "terraform"
    }
  }
}

# フェーズ2-c: Snowflake Kafka Connector の取り込み先。
# 親モジュールとはオブジェクトを共有せず、この module 専用の DB/schema/role/user を作る。
provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  user              = var.snowflake_admin_user
  authenticator     = "SNOWFLAKE_JWT"
  private_key       = file(var.snowflake_admin_private_key_path)
}
