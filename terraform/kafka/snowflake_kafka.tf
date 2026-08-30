############################################
# フェーズ2-c: Snowflake 側オブジェクト(この module 専用。親モジュールとは非共有)
#
# 前回記事 snowflake.tf の作り方を踏襲。Connector はキーペア認証で接続する。
# テーブル ENV_SENSOR_RAW は Terraform(snowflake_execute)で明示的に作成する
# (フェーズ4(b) で Connector 自動生成から変更。前回記事同様の型付きカラム + Connector メタデータ列)。
############################################

resource "tls_private_key" "kafka_connect" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

locals {
  # Snowflake / Connector とも「ヘッダ・フッタなしの1行」の鍵文字列を要求する
  kc_public_key_oneline = join("", [
    for line in split("\n", tls_private_key.kafka_connect.public_key_pem) :
    line if !startswith(line, "-----") && line != ""
  ])
  kc_private_key_oneline = join("", [
    for line in split("\n", tls_private_key.kafka_connect.private_key_pem_pkcs8) :
    line if !startswith(line, "-----") && line != ""
  ])

  sf_kafka_table_name = "ENV_SENSOR_RAW"
  sf_kafka_table_fqn  = "${snowflake_database.kafka.name}.${snowflake_schema.env_sensor_kafka.name}.${local.sf_kafka_table_name}"
}

resource "snowflake_database" "kafka" {
  name    = "IOT_STREAM_KAFKA_DB"
  comment = "MSK Connect + Snowflake Kafka Connector 検証用(前回記事の Firehose 版 IOT_STREAM_IOT_DB とは別 DB)"
}

resource "snowflake_schema" "env_sensor_kafka" {
  database            = snowflake_database.kafka.name
  name                = "ENV_SENSOR_KAFKA"
  is_transient        = false
  with_managed_access = false
}

resource "snowflake_account_role" "kafka_connect" {
  name    = "IOT_STREAM_KAFKA_CONNECT_ROLE"
  comment = "Snowflake Kafka Connector が Snowpipe Streaming で書き込むためのロール"
}

resource "snowflake_grant_privileges_to_account_role" "kc_database" {
  account_role_name = snowflake_account_role.kafka_connect.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.kafka.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "kc_schema" {
  account_role_name = snowflake_account_role.kafka_connect.name
  # テーブルは Terraform で明示作成するが、Connector 起動時の DESC / 万一のスキーマ進化に備えて
  # USAGE と CREATE TABLE を付与しておく。
  privileges = ["USAGE", "CREATE TABLE"]

  on_schema {
    schema_name = snowflake_schema.env_sensor_kafka.fully_qualified_name
  }
}

# 前回記事の snowflake.tf 同様、Preview の snowflake_table ではなく Stable な snowflake_execute で作成。
# カラムは前回記事 ENV_SENSOR_RAW(temperature/humidity/pressure/event_timestamp/device_id)+
# Snowflake Kafka Connector が付ける RECORD_METADATA(VARIANT)。
# CREATE TABLE IF NOT EXISTS なので、Connector が既に自動生成済みの環境では no-op。
resource "snowflake_execute" "env_sensor_raw_table" {
  execute = "CREATE TABLE IF NOT EXISTS ${local.sf_kafka_table_fqn} (RECORD_METADATA VARIANT, TEMPERATURE FLOAT, HUMIDITY FLOAT, PRESSURE FLOAT, EVENT_TIMESTAMP NUMBER, DEVICE_ID VARCHAR)"
  revert  = "DROP TABLE IF EXISTS ${local.sf_kafka_table_fqn}"

  depends_on = [snowflake_schema.env_sensor_kafka]
}

resource "snowflake_service_user" "kafka_connect" {
  name           = "IOT_STREAM_KAFKA_CONNECT_USER"
  comment        = "Snowflake Kafka Connector がキーペア認証で使用するサービスユーザー"
  rsa_public_key = local.kc_public_key_oneline
  default_role   = snowflake_account_role.kafka_connect.name
}

resource "snowflake_grant_account_role" "kc_to_user" {
  role_name = snowflake_account_role.kafka_connect.name
  user_name = snowflake_service_user.kafka_connect.name
}

# クリーンな apply では snowflake_execute(= TF admin ロール)がテーブル所有者になるため、
# Connector ロールが書き込めるよう INSERT / SELECT を明示付与する。
# (フェーズ4(b) 以前は Connector 自身がテーブルを作成・所有していたので、この grant は不要だった。
#  検証中に手で実行した `GRANT SELECT ... TO ROLE IOT_STREAM_TF_ADMIN_ROLE` も、
#  クリーン apply では admin ロールが所有者になるため不要になる。)
resource "snowflake_grant_privileges_to_account_role" "kc_table" {
  account_role_name = snowflake_account_role.kafka_connect.name
  privileges        = ["INSERT", "SELECT"]

  on_schema_object {
    object_type = "TABLE"
    object_name = local.sf_kafka_table_fqn
  }

  depends_on = [snowflake_execute.env_sensor_raw_table]
}
