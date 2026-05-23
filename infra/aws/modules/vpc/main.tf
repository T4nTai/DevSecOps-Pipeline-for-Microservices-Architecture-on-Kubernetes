locals {
  create_second_private_subnet = var.private_subnet_cidr_b != ""
  create_second_public_subnet  = var.public_subnet_cidr_b != ""
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name                                        = "${var.cluster_name}-vpc"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.cluster_name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${data.aws_region.current.name}a"
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                     = "${var.cluster_name}-public-subnet-a"
    "kubernetes.io/role/elb" = "1"
  })
}

# Optional second public subnet in AZ-b.
# Required when enabling multi-AZ for ingress NLB or API NLB.
# Set public_subnet_cidr_b alongside private_subnet_cidr_b (e.g. 10.0.11.0/24).
resource "aws_subnet" "public_b" {
  count                   = local.create_second_public_subnet ? 1 : 0
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr_b
  availability_zone       = "${data.aws_region.current.name}b"
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                     = "${var.cluster_name}-public-subnet-b"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  count          = local.create_second_public_subnet ? 1 : 0
  subnet_id      = aws_subnet.public_b[0].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.cluster_name}-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = merge(var.tags, { Name = "${var.cluster_name}-nat" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-private-rt" })

  lifecycle {
    # Kubespray adds a route for the pod CIDR (e.g. 10.233.0.0/16) directly on
    # this route table during cluster bootstrap. Ignoring [route] prevents
    # Terraform from removing it on the next apply. Trade-off: manually added
    # incorrect routes also won't be detected — audit this table periodically.
    ignore_changes = [route]
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${data.aws_region.current.name}a"

  tags = merge(var.tags, {
    Name                              = "${var.cluster_name}-private-subnet-a"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_subnet" "private_b" {
  count             = local.create_second_private_subnet ? 1 : 0
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidr_b
  availability_zone = "${data.aws_region.current.name}b"

  tags = merge(var.tags, {
    Name                              = "${var.cluster_name}-private-subnet-b"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_route_table_association" "private_b" {
  count          = local.create_second_private_subnet ? 1 : 0
  subnet_id      = aws_subnet.private_b[0].id
  route_table_id = aws_route_table.private.id
}

data "aws_region" "current" {}
