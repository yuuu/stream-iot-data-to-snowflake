############################################
# フェーズ2-c: NAT Gateway(MSK Connect が Snowflake へ 443 で出るため)
#
# private サブネットにデフォルトルートを追加する。単一 AZ・1 台のみ(検証用、コスト最小)。
# S3 は Gateway エンドポイント(無料)で NAT を経由させない。
############################################

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-kafka-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.project_name}-kafka-nat" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project_name}-kafka-s3-gw-endpoint" }
}
