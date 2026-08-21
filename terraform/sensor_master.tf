# Openflow Connector for PostgreSQL の取り込み先スキーマ。
# SENSORSテーブル自体はコネクタが初回スナップショット時に作成するため、ここでは作成しない。
resource "snowflake_schema" "sensor_master" {
  database            = snowflake_database.iot.name
  name                = "SENSOR_MASTER"
  is_transient        = false
  with_managed_access = false
}

resource "snowflake_warehouse" "openflow_ingest" {
  name                = "IOT_STREAM_OPENFLOW_WH"
  comment             = "Openflow Connector for PostgreSQLのレプリケーション/マージに使うWarehouse"
  warehouse_size      = "XSMALL"
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
}

resource "snowflake_account_role" "openflow_ingest" {
  name    = "IOT_STREAM_OPENFLOW_INGEST_ROLE"
  comment = "Openflow Connector for PostgreSQLがSENSOR_MASTERスキーマへ書き込むためのロール"
}

resource "snowflake_grant_privileges_to_account_role" "openflow_ingest_database" {
  account_role_name = snowflake_account_role.openflow_ingest.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.iot.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "openflow_ingest_schema" {
  account_role_name = snowflake_account_role.openflow_ingest.name
  privileges        = ["USAGE", "CREATE TABLE"]

  on_schema {
    schema_name = snowflake_schema.sensor_master.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "openflow_ingest_warehouse" {
  account_role_name = snowflake_account_role.openflow_ingest.name
  privileges        = ["USAGE", "OPERATE"]

  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.openflow_ingest.name
  }
}

# Openflow ConnectorがSnowflakeにキーペア認証で接続するためのユーザー(firehose.tfと同じパターン)。
resource "tls_private_key" "openflow_ingest" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

locals {
  openflow_ingest_public_key_oneline = join("", [
    for line in split("\n", tls_private_key.openflow_ingest.public_key_pem) :
    line if !startswith(line, "-----") && line != ""
  ])
}

resource "snowflake_service_user" "openflow_ingest" {
  name           = "IOT_STREAM_OPENFLOW_INGEST_USER"
  comment        = "Openflow Connector for PostgreSQLがキーペア認証で使用するサービスユーザー"
  rsa_public_key = local.openflow_ingest_public_key_oneline
  default_role   = snowflake_account_role.openflow_ingest.name
}

resource "snowflake_grant_account_role" "openflow_ingest_to_user" {
  role_name = snowflake_account_role.openflow_ingest.name
  user_name = snowflake_service_user.openflow_ingest.name
}

# OpenflowランタイムからRDSへの接続許可。
# Runtime作成時にこのExternal Access Integrationをアタッチする操作自体はSnowsight UIで行う(README参照)。
resource "snowflake_network_rule" "rds_postgres" {
  database   = snowflake_database.iot.name
  schema     = snowflake_schema.sensor_master.name
  name       = "RDS_POSTGRES_NETWORK_RULE"
  mode       = "EGRESS"
  type       = "HOST_PORT"
  value_list = ["${aws_db_instance.sensor_master.address}:5432"]
  comment    = "Openflow Connector for PostgreSQL -> RDS(sensor_master)"
}

# 執筆時点(2026-08)では snowflake_external_access_integration リソースが提供されていないため、
# snowflake.tf / dynamic_table.tf と同じ流儀で snowflake_execute を使う。
resource "snowflake_execute" "rds_postgres_eai" {
  execute = <<-SQL
    CREATE EXTERNAL ACCESS INTEGRATION IOT_STREAM_RDS_POSTGRES_EAI
      ALLOWED_NETWORK_RULES = (${snowflake_network_rule.rds_postgres.fully_qualified_name})
      ENABLED = TRUE
      COMMENT = 'Openflow Connector for PostgreSQL -> RDS(sensor_master)'
  SQL

  revert = "DROP EXTERNAL ACCESS INTEGRATION IOT_STREAM_RDS_POSTGRES_EAI"
}
