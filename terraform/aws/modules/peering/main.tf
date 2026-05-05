data "aws_vpc" "tools" {
  tags = { Name = "${var.tools_cluster_name}-vpc" }
}

data "aws_vpc" "apps" {
  tags = { Name = "${var.apps_cluster_name}-vpc" }
}

data "aws_route_table" "tools_private" {
  tags = { Name = "${var.tools_cluster_name}-private-rt" }
}

data "aws_route_tables" "apps_private" {
  tags = { Name = "${var.apps_cluster_name}-private-rt" }
}

resource "aws_vpc_peering_connection" "tools_to_apps" {
  vpc_id      = data.aws_vpc.tools.id
  peer_vpc_id = data.aws_vpc.apps.id
  auto_accept = true

  tags = { Name = "${var.tools_cluster_name}-to-${var.apps_cluster_name}" }
}

resource "aws_route" "tools_to_apps" {
  route_table_id            = data.aws_route_table.tools_private.id
  destination_cidr_block    = var.apps_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.tools_to_apps.id
}

resource "aws_route" "apps_to_tools" {
  for_each = toset(data.aws_route_tables.apps_private.ids)

  route_table_id            = each.value
  destination_cidr_block    = var.tools_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.tools_to_apps.id
}
