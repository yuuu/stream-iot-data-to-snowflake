############################################
# 踏み台 EC2 (SSH ジャンプホスト)
############################################

# AL2023 arm64 の最新 AMI
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# 踏み台の SSH 鍵は Terraform 内で生成し、秘密鍵を certs/ (gitignore 済み) へ出力する
resource "tls_private_key" "bastion" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "bastion" {
  key_name   = "${var.project_name}-kafka-bastion"
  public_key = tls_private_key.bastion.public_key_openssh
}

resource "local_sensitive_file" "bastion_private_key" {
  content         = tls_private_key.bastion.private_key_openssh
  filename        = "${path.module}/certs/bastion_ed25519.pem"
  file_permission = "0600"
}

# SSM Session Manager をフォールバック接続手段として使えるようにする
data "aws_iam_policy_document" "bastion_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.project_name}-kafka-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume_role.json
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 踏み台上で client.properties を組み立てる際に SCRAM パスワードを引けるようにする
data "aws_iam_policy_document" "bastion_read_scram_secrets" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for u in var.scram_users : aws_secretsmanager_secret.scram[u].arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.scram.arn]
  }
}

resource "aws_iam_role_policy" "bastion_read_scram_secrets" {
  name   = "${var.project_name}-kafka-bastion-read-scram"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.bastion_read_scram_secrets.json
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.project_name}-kafka-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-kafka-bastion-sg"
  description = "SSH access to the Kafka verification bastion"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH from work terminals"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-kafka-bastion-sg" }
}

locals {
  bastion_user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf install -y java-17-amazon-corretto-headless tar gzip

    KAFKA_VER=3.8.1
    SCALA_VER=2.13
    cd /opt
    curl -fsSL "https://archive.apache.org/dist/kafka/$${KAFKA_VER}/kafka_$${SCALA_VER}-$${KAFKA_VER}.tgz" -o kafka.tgz
    tar xzf kafka.tgz
    rm -f kafka.tgz
    ln -sfn "/opt/kafka_$${SCALA_VER}-$${KAFKA_VER}" /opt/kafka
    echo 'export PATH=$PATH:/opt/kafka/bin' > /etc/profile.d/kafka.sh
  EOF
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = aws_key_pair.bastion.key_name
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true
  user_data                   = local.bastion_user_data

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project_name}-kafka-bastion" }
}
