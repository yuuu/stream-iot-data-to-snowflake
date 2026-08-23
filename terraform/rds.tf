# センサーのマスターデータ(sensor_id, name, location)を持つRDS PostgreSQLインスタンス。
# このテーブル自体はTerraform管理外とし、terraform/sql/sensors.sqlをpsqlで手動実行して作成する
# (aws_iot_certificateと同じ「Terraformで扱いにくいものは手動運用にする」方針。README参照)。

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_db_subnet_group" "sensor_master" {
  name       = "${var.project_name}-sensor-master"
  subnet_ids = data.aws_subnets.default.ids
}

# Openflow Connector for PostgreSQL(Snowflake Deployments/SPCS)からの接続元は、
# Snowflakeが提供する静的Egress IP(SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES())。
# このIPは90日で失効するため、egress_ip_sync.tfのAWS Lambdaが週次で自動的に
# ingressルールを最新のIPレンジへ同期する。
resource "aws_security_group" "sensor_master" {
  name        = "${var.project_name}-sensor-master-sg"
  description = "Allow inbound PostgreSQL from Snowflake Openflow static egress IPs"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "PostgreSQL from Snowflake Openflow static egress IPs (kept in sync by egress_ip_sync.tf Lambda)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.rds_allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    # ingressはegress_ip_sync.tfのAWS Lambdaが実行時にEC2 APIで直接書き換える。
    # ここでの初期値との差分でterraform applyのたびに巻き戻さないようにする。
    ignore_changes = [ingress]
  }
}

# RDSではALTER SYSTEMが使えないため、論理レプリケーションの有効化はカスタムパラメータグループで行う。
# 新規作成のインスタンスにこのパラメータグループを最初からアタッチする場合は再起動不要
# (既存インスタンスで値を変更した場合は再起動が必要な静的パラメータ)。
resource "aws_db_parameter_group" "sensor_master" {
  name   = "${var.project_name}-sensor-master-pg16"
  family = "postgres16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "random_password" "sensor_master" {
  length  = 32
  special = false
}

resource "aws_db_instance" "sensor_master" {
  identifier     = "${var.project_name}-sensor-master"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.rds_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.sensors_db_name
  username = var.postgres_master_username
  password = random_password.sensor_master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.sensor_master.name
  vpc_security_group_ids = [aws_security_group.sensor_master.id]
  parameter_group_name   = aws_db_parameter_group.sensor_master.name

  # デモ用途のため public accessible。実運用ではPrivateLink等の非公開接続を検討すること(README参照)。
  publicly_accessible = true

  auto_minor_version_upgrade = true
  backup_retention_period    = 0
  skip_final_snapshot        = true
  apply_immediately          = true
}
