resource "aws_security_group" "bastion" {
  name        = "${var.cluster_name}-bastion-sg"
  description = "Bastion host - SSH from allowed CIDR only. Set allowed_ssh_cidr to your IP, not 0.0.0.0/0."
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from admin CIDR (set to your IP, not 0.0.0.0/0)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-bastion-sg" })
}

resource "aws_security_group" "ingress_nlb" {
  name        = "${var.cluster_name}-ingress-nlb-sg"
  description = "Ingress NLB - allow HTTP/HTTPS from public internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from allowed CIDRs"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "HTTPS from allowed CIDRs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-ingress-nlb-sg" })
}

# ── Control plane — etcd isolation ───────────────────────────────────────────
# Separate SG applied only to control plane nodes.
# Self-referencing rules (self = true) mean ONLY instances carrying THIS SG
# can reach etcd ports 2379/2380 — worker nodes never have this SG attached.
#
# Defense-in-depth note: k8s_nodes_sg still has a broad "all internal" rule
# that technically covers etcd ports too. The intent is to remove that broad
# rule in a future hardening pass and rely solely on specific port rules +
# this self-referencing etcd SG for control-plane-to-control-plane traffic.
resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane-sg"
  description = "Control plane nodes — etcd ports accessible only by other control planes (self-reference)"
  vpc_id      = var.vpc_id

  ingress {
    description = "etcd client — kube-apiserver to etcd (stacked topology)"
    from_port   = 2379
    to_port     = 2379
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "etcd peer — leader election and log replication between etcd members"
    from_port   = 2380
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-control-plane-sg" })
}

resource "aws_security_group" "k8s_nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "K8s nodes - SSH from bastion, API from bastion, NodePort from anywhere"
  vpc_id      = var.vpc_id

  ingress {
    description     = "SSH from bastion only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description     = "K8s API from bastion"
    from_port       = 6443
    to_port         = 6443
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description = "K8s API from admin IP"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Internal cluster traffic (all private subnets)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.private_subnet_cidrs
  }

  ingress {
    description     = "NodePort HTTP from ingress NLB"
    from_port       = 30080
    to_port         = 30080
    protocol        = "tcp"
    security_groups = [aws_security_group.ingress_nlb.id]
  }

  ingress {
    description     = "NodePort HTTPS from ingress NLB"
    from_port       = 30443
    to_port         = 30443
    protocol        = "tcp"
    security_groups = [aws_security_group.ingress_nlb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-nodes-sg" })
}
