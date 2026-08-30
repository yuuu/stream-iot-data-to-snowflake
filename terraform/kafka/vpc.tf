locals {
  # 3 つのプライベートサブネット(MSK ブローカー / IoT VPC destination の ENI / MSK Connect 用)
  private_subnet_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)] # /20 x3: 10.20.0.0/20, 10.20.16.0/20, 10.20.32.0/20
  # 踏み台用のパブリックサブネット 1 つ
  public_subnet_cidr = cidrsubnet(var.vpc_cidr, 8, 48) # /24: 10.20.48.0/24
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # IoT ルールエンジンの ENI がブローカー FQDN を解決するために必須
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-kafka-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-kafka-igw" }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${var.project_name}-kafka-private-${var.availability_zones[count.index]}" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidr
  availability_zone       = var.availability_zones[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-kafka-public-${var.availability_zones[0]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.project_name}-kafka-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# フェーズ2-a ではプライベートサブネットにデフォルトルートを張らない
# (踏み台はパブリック IP 直付けで足り、MSK ブローカーは外向き通信不要)。
# フェーズ2-c で MSK Connect が Snowflake へ出るために NAT Gateway をこの RT に追加する。
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-kafka-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
