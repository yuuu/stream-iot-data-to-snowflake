# Firehose がキーペア認証でSnowflakeに接続するための鍵ペア。
# Terraform内で生成することで、秘密鍵を手作業でopensslしたりコピペしたりする必要をなくす。
resource "tls_private_key" "firehose_ingest" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

locals {
  # Snowflake / Firehose 双方とも「ヘッダ・フッタなしの1行」の鍵文字列を要求する
  firehose_public_key_oneline = join("", [
    for line in split("\n", tls_private_key.firehose_ingest.public_key_pem) :
    line if !startswith(line, "-----") && line != ""
  ])

  firehose_private_key_oneline = join("", [
    for line in split("\n", tls_private_key.firehose_ingest.private_key_pem_pkcs8) :
    line if !startswith(line, "-----") && line != ""
  ])

  env_sensor_table_fqn = "${snowflake_database.iot.name}.${snowflake_schema.env_sensor.name}.ENV_SENSOR_RAW"
}

resource "snowflake_database" "iot" {
  name    = "IOT_STREAM_IOT_DB"
  comment = "IoTデバイスから収集したテレメトリを格納するデータベース"
}

resource "snowflake_schema" "env_sensor" {
  database            = snowflake_database.iot.name
  name                = "ENV_SENSOR"
  is_transient        = false
  with_managed_access = false
}

# 執筆時点(2026-07)では snowflake_table は Preview 機能のため、Stable な snowflake_execute で代替する
resource "snowflake_execute" "env_sensor_raw_table" {
  execute = "CREATE TABLE ${local.env_sensor_table_fqn} (temperature FLOAT, humidity FLOAT, pressure FLOAT, event_timestamp NUMBER, device_id VARCHAR)"
  revert  = "DROP TABLE ${local.env_sensor_table_fqn}"
}

resource "snowflake_account_role" "firehose_ingest" {
  name    = "IOT_STREAM_FIREHOSE_INGEST_ROLE"
  comment = "Kinesis Data FirehoseがENV_SENSOR_RAWへINSERTするためのロール"
}

resource "snowflake_grant_privileges_to_account_role" "firehose_ingest_database" {
  account_role_name = snowflake_account_role.firehose_ingest.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.iot.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "firehose_ingest_schema" {
  account_role_name = snowflake_account_role.firehose_ingest.name
  privileges        = ["USAGE"]

  on_schema {
    schema_name = snowflake_schema.env_sensor.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "firehose_ingest_table" {
  account_role_name = snowflake_account_role.firehose_ingest.name
  privileges        = ["INSERT", "SELECT"]

  on_schema_object {
    object_type = "TABLE"
    object_name = local.env_sensor_table_fqn
  }

  depends_on = [snowflake_execute.env_sensor_raw_table]
}

resource "snowflake_service_user" "firehose_ingest" {
  name           = "IOT_STREAM_FIREHOSE_INGEST_USER"
  comment        = "Kinesis Data Firehoseがキーペア認証で使用するサービスユーザー"
  rsa_public_key = local.firehose_public_key_oneline
  default_role   = snowflake_account_role.firehose_ingest.name
}

resource "snowflake_grant_account_role" "firehose_ingest_to_user" {
  role_name = snowflake_account_role.firehose_ingest.name
  user_name = snowflake_service_user.firehose_ingest.name
}
