############################################
# SASL/SCRAM 認証情報 (Secrets Manager + CMK)
############################################

data "aws_caller_identity" "current" {}

# MSK の SASL/SCRAM シークレットは「顧客管理 KMS キー」で暗号化する必要がある
# (デフォルトの aws/secretsmanager キーは不可)。
resource "aws_kms_key" "scram" {
  description             = "${var.project_name} MSK SASL/SCRAM secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowMSKAndSecretsManager"
        Effect    = "Allow"
        Principal = { Service = ["kafka.amazonaws.com", "secretsmanager.amazonaws.com"] }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:CreateGrant", "kms:DescribeKey"]
        Resource  = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "scram" {
  name          = "alias/${var.project_name}-msk-scram"
  target_key_id = aws_kms_key.scram.key_id
}

resource "random_password" "scram" {
  for_each = toset(var.scram_users)
  length   = 24
  special  = false # MSK SCRAM パスワードで問題になりうる記号を避ける
}

# シークレット名は "AmazonMSK_" プレフィックス必須。
# recovery_window_in_days = 0: 検証用途。デフォルト(30日)だと destroy 後 30 日間
# 同名シークレットを再作成できず「apply 一発で再現」できないため即時削除にする。
# NOTE: "msk-connect" ユーザーは MSK Connect が IAM 認証を使うため未使用(認証方式の対比として残置。
#       経緯は WORK_NOTES_kafka.md の認証方式対応表を参照)。
resource "aws_secretsmanager_secret" "scram" {
  for_each                = toset(var.scram_users)
  name                    = "AmazonMSK_${var.project_name}_${each.key}"
  kms_key_id              = aws_kms_key.scram.arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "scram" {
  for_each  = toset(var.scram_users)
  secret_id = aws_secretsmanager_secret.scram[each.key].id
  secret_string = jsonencode({
    username = each.key
    password = random_password.scram[each.key].result
  })
}

# MSK サービスがシークレットを読めるようにするリソースポリシー
resource "aws_secretsmanager_secret_policy" "scram" {
  for_each   = toset(var.scram_users)
  secret_arn = aws_secretsmanager_secret.scram[each.key].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSKafkaResourcePolicy"
        Effect    = "Allow"
        Principal = { Service = "kafka.amazonaws.com" }
        Action    = "secretsmanager:GetSecretValue"
        Resource  = aws_secretsmanager_secret.scram[each.key].arn
      }
    ]
  })
}

############################################
# セキュリティグループ
############################################

resource "aws_security_group" "msk" {
  name        = "${var.project_name}-kafka-msk-sg"
  description = "MSK broker access from within the VPC"
  vpc_id      = aws_vpc.this.id

  # 検証簡略化のため VPC CIDR から Kafka / ZooKeeper ポートを許可する。
  # 本番では踏み台 SG / IoT VPC destination SG / MSK Connect SG を個別に参照して絞る。
  ingress {
    description = "Kafka listeners (plaintext/TLS/SASL_SCRAM/SASL_IAM)"
    from_port   = 9092
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "ZooKeeper (plaintext/TLS)"
    from_port   = 2181
    to_port     = 2182
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "inter-broker"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-kafka-msk-sg" }
}

############################################
# MSK Provisioned クラスタ
############################################

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/${var.project_name}-kafka"
  retention_in_days = 14
}

resource "aws_msk_cluster" "this" {
  cluster_name           = "${var.project_name}-kafka"
  kafka_version          = var.kafka_version
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = var.broker_instance_type
    client_subnets  = aws_subnet.private[*].id
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.broker_ebs_volume_size
      }
    }
  }

  # SASL/SCRAM と IAM を併用で有効化する。
  # - IoT Rule の Kafka Action は IAM 非対応 → SASL/SCRAM で接続(iot-ingest ユーザー)
  # - MSK Connect は SASL/SCRAM が実質不可(worker 設定で sasl.* がブロックされる)→ IAM で接続
  # - Karafka(ローカル + SSH ポートフォワード)は SASL/SCRAM のまま(karafka ユーザー)
  # 経緯と認証方式の対応表は WORK_NOTES_kafka.md 参照。
  client_authentication {
    sasl {
      scram = true
      iam   = true
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS" # SASL/SCRAM は 9096/TLS 前提
      in_cluster    = true
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  tags = { Name = "${var.project_name}-kafka" }
}

# SCRAM シークレットをクラスタへ関連付け
resource "aws_msk_scram_secret_association" "this" {
  cluster_arn     = aws_msk_cluster.this.arn
  secret_arn_list = [for u in var.scram_users : aws_secretsmanager_secret.scram[u].arn]

  depends_on = [aws_secretsmanager_secret_version.scram]
}
