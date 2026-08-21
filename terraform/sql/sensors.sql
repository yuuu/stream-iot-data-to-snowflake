-- terraform apply で作成した RDS PostgreSQL インスタンスに対して、マスターユーザーで実行する手動セットアップSQL。
--
--   psql "host=<rds_endpoint> port=5432 dbname=<sensors_db_name> user=<postgres_master_username> sslmode=require"
--
-- 実行後の値(REPLACE_ME_*)は terraform.tfvars / Openflow コネクタ設定に転記すること。README参照。

-- 1. センサーのマスターテーブル
--    sensor_id は Openflow Connector for PostgreSQL の識別キー(REPLICA IDENTITY)としても、
--    ENV_SENSOR_HOURLY_AVG.device_id との JOIN キーとしても使われる。
CREATE TABLE IF NOT EXISTS sensors (
    sensor_id VARCHAR PRIMARY KEY,
    name      VARCHAR NOT NULL,
    location  VARCHAR NOT NULL
);

-- 2. サンプルデータ
--    sensor_id は env-sensor.ino が publish するトピック "env-sensor/<chip-id>" の <chip-id> 部分
--    (= ENV_SENSOR_RAW.device_id) に合わせること。
INSERT INTO sensors (sensor_id, name, location) VALUES
    ('REPLACE_ME_CHIP_ID', 'Living Room Sensor', 'Living Room')
ON CONFLICT (sensor_id) DO NOTHING;

-- 3. Openflow Connector for PostgreSQL 用のレプリケーションユーザー
--    RDSでは ALTER ROLE ... REPLICATION が使えないため、rds_replication ロールを付与する。
CREATE USER openflow_connector WITH PASSWORD 'REPLACE_ME_STRONG_PASSWORD';
GRANT rds_replication TO openflow_connector;
GRANT SELECT ON sensors TO openflow_connector;

-- 4. Publication
--    Openflow Connector for PostgreSQL のセットアップ手順に従い、レプリケーション対象テーブルを
--    含む Publication を作成する(PostgreSQL 13+ では publish_via_partition_root = true を推奨)。
CREATE PUBLICATION openflow_publication FOR TABLE sensors WITH (publish_via_partition_root = true);
