provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  user              = var.snowflake_admin_user
  authenticator     = "SNOWFLAKE_JWT"
  private_key       = var.snowflake_admin_private_key
}
