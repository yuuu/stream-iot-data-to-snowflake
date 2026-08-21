# Dynamic Tableのリフレッシュ専用Warehouse。
# Firehoseからのストリーミング取り込みには使われないため、用途を分離して管理する。
resource "snowflake_warehouse" "dynamic_table" {
  name                = "IOT_STREAM_DYNAMIC_TABLE_WH"
  comment             = "ENV_SENSOR_HOURLY_AVG Dynamic Tableのリフレッシュに使うWarehouse"
  warehouse_size      = "XSMALL"
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
}

locals {
  env_sensor_hourly_avg_table_fqn = "${snowflake_database.iot.name}.${snowflake_schema.env_sensor.name}.ENV_SENSOR_HOURLY_AVG"
}

# 執筆時点(2026-08)では snowflake_dynamic_table はPreview機能のため、Stableなsnowflake_executeで代替する
resource "snowflake_execute" "env_sensor_hourly_avg_table" {
  execute = <<-SQL
    CREATE DYNAMIC TABLE ${local.env_sensor_hourly_avg_table_fqn}
      TARGET_LAG = '1 hour'
      WAREHOUSE = ${snowflake_warehouse.dynamic_table.name}
      AS
      SELECT
        device_id,
        DATE_TRUNC('HOUR', TO_TIMESTAMP_NTZ(event_timestamp / 1000)) AS hour_bucket,
        AVG(temperature) AS avg_temperature,
        AVG(humidity) AS avg_humidity,
        AVG(pressure) AS avg_pressure
      FROM ${local.env_sensor_table_fqn}
      GROUP BY device_id, hour_bucket
  SQL

  revert = "DROP DYNAMIC TABLE ${local.env_sensor_hourly_avg_table_fqn}"

  depends_on = [snowflake_execute.env_sensor_raw_table]
}
