locals {
  env_sensor_hourly_avg_enriched_table_fqn = "${snowflake_database.iot.name}.${snowflake_schema.env_sensor.name}.ENV_SENSOR_HOURLY_AVG_ENRICHED"
  sensor_master_table_fqn                  = "${snowflake_database.iot.name}.${snowflake_schema.sensor_master.name}.SENSORS"
}

# NOTE: SENSOR_MASTER.SENSORS は Openflow Connector for PostgreSQL が初回スナップショット時に作成するテーブルであり、
# Terraformでは管理していない。そのため、このDynamic Tableは以下の順序で作成する必要がある(README「実行手順」参照)。
#   1. terraform apply (このリソース以外を作成)
#   2. Snowsight UIでOpenflowのDeployment/Runtime/コネクタを構築し、初回スナップショットを完了させる
#   3. 再度 terraform apply してこのDynamic Tableを作成する
resource "snowflake_execute" "env_sensor_hourly_avg_enriched_table" {
  execute = <<-SQL
    CREATE DYNAMIC TABLE ${local.env_sensor_hourly_avg_enriched_table_fqn}
      TARGET_LAG = '1 hour'
      WAREHOUSE = ${snowflake_warehouse.dynamic_table.name}
      AS
      SELECT
        hourly.hour_bucket,
        hourly.device_id,
        sensors.name,
        sensors.location,
        hourly.avg_temperature,
        hourly.avg_humidity,
        hourly.avg_pressure
      FROM ${local.env_sensor_hourly_avg_table_fqn} AS hourly
      LEFT JOIN ${local.sensor_master_table_fqn} AS sensors
        ON hourly.device_id = sensors.sensor_id
  SQL

  revert = "DROP DYNAMIC TABLE ${local.env_sensor_hourly_avg_enriched_table_fqn}"

  depends_on = [
    snowflake_execute.env_sensor_hourly_avg_table,
    snowflake_schema.sensor_master,
  ]
}
