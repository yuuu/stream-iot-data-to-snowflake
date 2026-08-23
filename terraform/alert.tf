# TEMPERATURE(気温)が30度を超えたことをSnowflake Alertで検知する。
# 検知した行はログテーブルに記録しつつ、Notification Integration経由でメール通知する。

# Alertの条件評価専用Warehouse。
# Firehoseからのストリーミング取り込み・Dynamic Tableのリフレッシュとは用途を分離して管理する。
resource "snowflake_warehouse" "alert" {
  name                = "IOT_STREAM_ALERT_WH"
  comment             = "ENV_SENSOR_RAWのTEMPERATURE監視Alertの条件評価に使うWarehouse"
  warehouse_size      = "XSMALL"
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
}

locals {
  env_sensor_temperature_alert_log_table_fqn      = "${snowflake_database.iot.name}.${snowflake_schema.env_sensor.name}.ENV_SENSOR_TEMPERATURE_ALERT_LOG"
  temperature_alert_notification_integration_name = "IOT_STREAM_TEMPERATURE_ALERT_EMAIL_INT"
  temperature_alert_name                          = "IOT_STREAM_ENV_SENSOR_TEMPERATURE_ALERT"
  # Alertはスキーマ配下のオブジェクトなので、セッションのカレントデータベース任せにせず完全修飾名で指定する
  temperature_alert_fqn = "${snowflake_database.iot.name}.${snowflake_schema.env_sensor.name}.${local.temperature_alert_name}"

  # Alertの条件・アクション内で使い回すため、「通知対象の行」を返すSELECT文をローカル変数化しておく。
  # 単に temperature > 30 の新規行を検知するだけだと、閾値超過が続く限り毎回のスケジュール実行(1分毎)で
  # 検知され続けてしまう(=毎分メール通知される)。そこで device_id ごとにLAG()で直前の行の温度と比較し、
  # 「直前は30度以下(または直前行が存在しない) → 今回30度超」という立ち上がりエッジの行だけに絞り込む。
  # LAGはテーブル全体を対象に計算し、絞り込みだけを LAST_SUCCESSFUL_SCHEDULED_TIME()〜SCHEDULED_TIME() の
  # 新規分に限定することで、ウィンドウ境界をまたいでも直前の行を正しく参照できるようにしている。
  #
  # 注意: SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME() はAlertの「前回成功した実行時刻」を返すが、
  # 初回実行時(Alertを作り直した直後を含む)は非常に古い時刻を返し、下限が事実上無いのと同義になる。
  # そのままだと、閾値付近で細かく上下する温度データがある場合、テーブルの全履歴分の「立ち上がり」を
  # 一括で検知・通知してしまう。それを防ぐため、下限は「SCHEDULED_TIME()から遡って最大5分前」に
  # GREATESTでクランプし、Alertが再作成されても常に直近分のみを対象にするようにしている
  # (SCHEDULE = '1 MINUTE' に対して5分のバッファを持たせ、多少の実行遅延も許容する)。
  temperature_alert_crossing_rows_query = <<-SQL
    SELECT device_id, temperature, event_timestamp
    FROM (
      SELECT
        device_id,
        temperature,
        event_timestamp,
        LAG(temperature) OVER (PARTITION BY device_id ORDER BY event_timestamp) AS prev_temperature
      FROM ${local.env_sensor_table_fqn}
    )
    WHERE TO_TIMESTAMP_LTZ(event_timestamp / 1000)
            BETWEEN GREATEST(
                      SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                      DATEADD('minute', -5, SNOWFLAKE.ALERT.SCHEDULED_TIME())
                    )
                    AND SNOWFLAKE.ALERT.SCHEDULED_TIME()
      AND temperature > 30
      AND (prev_temperature IS NULL OR prev_temperature <= 30)
  SQL
}

# アラート発報履歴を残すためのログテーブル。
# 執筆時点(2026-08)では snowflake_table は Preview 機能のため、Stable な snowflake_execute で代替する
resource "snowflake_execute" "env_sensor_temperature_alert_log_table" {
  execute = "CREATE TABLE ${local.env_sensor_temperature_alert_log_table_fqn} (device_id VARCHAR, temperature FLOAT, event_timestamp NUMBER, alerted_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())"
  revert  = "DROP TABLE ${local.env_sensor_temperature_alert_log_table_fqn}"
}

# Alertのアクションからメール通知するためのNotification Integration。
# 受信先アドレスは、このSnowflakeアカウント上でメール検証済みのユーザーのものである必要がある(README参照)。
#
# snowflake_notification_integration リソースはTYPE=EMAILに対応しておらず、かつPreview機能でもあるため、
# 他のPreview代替リソースと同様にStableなsnowflake_executeで代替する
resource "snowflake_execute" "temperature_alert_notification_integration" {
  execute = <<-SQL
    CREATE NOTIFICATION INTEGRATION ${local.temperature_alert_notification_integration_name}
      TYPE = EMAIL
      ENABLED = TRUE
      DEFAULT_RECIPIENTS = ('${var.alert_notification_email}')
      DEFAULT_SUBJECT = 'ENV_SENSOR_RAW 温度アラート'
  SQL

  revert = "DROP NOTIFICATION INTEGRATION ${local.temperature_alert_notification_integration_name}"
}

# 執筆時点(2026-08)では snowflake_alert はPreview機能のため、Stableなsnowflake_executeで代替する
#
# THEN句は単一のSQL文である必要があるため、EXECUTE IMMEDIATE $$ ... $$ でSnowflake Scripting
# ブロックにまとめ、ログテーブルへのINSERTとメール通知の2つのアクションを1文にしている。
resource "snowflake_execute" "temperature_alert" {
  execute = <<-SQL
    CREATE ALERT ${local.temperature_alert_fqn}
      WAREHOUSE = ${snowflake_warehouse.alert.name}
      SCHEDULE = '1 MINUTE'
      IF (EXISTS (
        ${local.temperature_alert_crossing_rows_query}
      ))
      THEN
        EXECUTE IMMEDIATE $$
          DECLARE
            triggered_device_ids VARCHAR;
          BEGIN
            INSERT INTO ${local.env_sensor_temperature_alert_log_table_fqn} (device_id, temperature, event_timestamp)
              ${local.temperature_alert_crossing_rows_query};

            -- 同一実行で複数デバイスが同時にエッジ検知された場合はカンマ区切りでまとめる。
            -- 同一デバイスが同一実行内で複数回エッジ検知される(閾値を跨ぎ直す)こともあるため DISTINCT で重複排除する
            SELECT LISTAGG(DISTINCT device_id, ', ') INTO :triggered_device_ids
              FROM (${local.temperature_alert_crossing_rows_query});

            CALL SYSTEM$SEND_EMAIL(
              '${local.temperature_alert_notification_integration_name}',
              '${var.alert_notification_email}',
              'ENV_SENSOR_RAW 温度アラート',
              'DEVICE_ID=' || :triggered_device_ids || 'の温度が30度を超えました。'
            );

            RETURN 'ALERTED';
          END;
        $$
  SQL

  revert = "DROP ALERT ${local.temperature_alert_fqn}"

  depends_on = [
    snowflake_execute.env_sensor_raw_table,
    snowflake_execute.env_sensor_temperature_alert_log_table,
    snowflake_execute.temperature_alert_notification_integration,
  ]
}

# CREATE ALERTで作成した直後のAlertはSUSPENDED状態のため、明示的にRESUMEする
#
# executeの文字列がtemperature_alertの変更前後で同一だと、Alert本体がexecute文の変更で
# DROP→CREATEされ直してもterraformはこのresource自体に差分がないと判断し、RESUMEを再実行しない
# (=作り直されたAlertがSUSPENDEDのまま放置される)。それを防ぐため、temperature_alertのidを
# SQLコメントとして埋め込み、Alert本体が置き換わるたびにこのresourceも強制的に再実行されるようにする。
resource "snowflake_execute" "temperature_alert_resume" {
  execute = "ALTER ALERT ${local.temperature_alert_fqn} RESUME -- alert_execution_id=${snowflake_execute.temperature_alert.id}"
  revert  = "ALTER ALERT ${local.temperature_alert_fqn} SUSPEND"

  depends_on = [snowflake_execute.temperature_alert]
}
