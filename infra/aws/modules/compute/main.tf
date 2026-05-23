data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu.id

  # apps_worker reuses worker_instance_type if not explicitly set
  apps_worker_instance_type = (
    var.apps_worker_instance_type != "" ? var.apps_worker_instance_type : var.worker_instance_type
  )

  # Secondary control planes go to AZ-b when available for HA etcd quorum.
  # With 3-node etcd (1 primary in AZ-a + 2 secondary in AZ-b), the cluster
  # survives a full AZ-a failure: AZ-b still has 2 of 3 members (quorum intact).
  # Falls back to AZ-a if private_subnet_b_id is not set (single-AZ mode).
  secondary_cp_subnet = (
    var.private_subnet_b_id != "" ? var.private_subnet_b_id : var.private_subnet_id
  )

  # Additional SGs for control plane nodes: base + dedicated etcd SG.
  # The etcd SG (control_plane_sg_id) uses self-referencing rules so only
  # nodes carrying it can reach etcd ports 2379/2380.
  control_plane_sgs = compact([var.k8s_nodes_sg_id, var.control_plane_sg_id])
}

resource "aws_key_pair" "this" {
  key_name   = "${var.cluster_name}-key"
  public_key = file(var.public_key_path)
  tags       = var.tags
}

# ── Bastion ───────────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  count                  = var.create_bastion ? 1 : 0
  ami                    = local.ami_id # uses Packer AMI when set, otherwise latest Ubuntu 22.04
  instance_type          = var.bastion_instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [var.bastion_sg_id]
  key_name               = aws_key_pair.this.key_name

  root_block_device {
    volume_size           = 10
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-bastion", Role = "bastion" })
}

# ── Control plane ─────────────────────────────────────────────────────────────
# Profile: base (EBS CSI + autoscaler). No KMS or Route53 needed.

resource "aws_instance" "control_plane" {
  count                  = var.control_plane_count
  ami                    = local.ami_id
  instance_type          = var.control_plane_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = local.control_plane_sgs # k8s_nodes_sg + etcd-only control_plane_sg
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = var.base_instance_profile_name

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-control-plane-${count.index + 1}"
    Role = "control-plane"
  })
}

# ── Secondary control plane nodes ─────────────────────────────────────────────
# Profile: base. Same rationale as primary control plane.

resource "aws_instance" "control_plane_secondary" {
  count                  = var.secondary_control_plane_count
  ami                    = local.ami_id
  instance_type          = var.secondary_control_plane_instance_type
  subnet_id              = local.secondary_cp_subnet # AZ-b when available, else AZ-a
  vpc_security_group_ids = local.control_plane_sgs   # k8s_nodes_sg + etcd-only control_plane_sg
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = var.base_instance_profile_name

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-control-plane-${var.control_plane_count + count.index + 1}"
    Role = "control-plane"
  })
}

# ── On-demand workers — stateful (Vault, Harbor, cert-manager) ────────────────
# Profile: stateful (EBS CSI + autoscaler + KMS + Route53).
# These nodes host Vault (needs KMS unseal) and cert-manager (needs Route53 DNS-01).
# NOTE: Pin Vault and cert-manager pods to these nodes via nodeSelector/affinity.

resource "aws_instance" "worker" {
  count                  = var.worker_count
  ami                    = local.ami_id
  instance_type          = var.worker_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.k8s_nodes_sg_id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = var.stateful_instance_profile_name

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name     = "${var.cluster_name}-worker-${count.index + 1}"
    Role     = "worker"
    NodeRole = "stateful"
  })
}

# ── Apps workers — dedicated nodes for microservices namespace ─────────────────
# Profile: base (EBS CSI + autoscaler only).
# Microservices do not need KMS or Route53 access.

resource "aws_instance" "apps_worker" {
  count                  = var.apps_worker_count
  ami                    = local.ami_id
  instance_type          = local.apps_worker_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.k8s_nodes_sg_id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = var.base_instance_profile_name

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name     = "${var.cluster_name}-apps-worker-${count.index + 1}"
    Role     = "apps-worker"
    NodeRole = "apps"
  })
}

# ── Spot workers — stateless (Jenkins agents, SonarQube) ─────────────────────
# Profile: base (EBS CSI + autoscaler only).
# Spot nodes run stateless workloads — no elevated permissions needed.
# Autoscaler tags belong here (on ASG/LaunchTemplate), NOT on static instances above.

# ── Spot workers — stateless (Jenkins agents, SonarQube) ─────────────────────
# Uses mixed_instances_policy with multiple instance types so that a single
# instance-type capacity shortage or price spike doesn't preempt all nodes
# simultaneously. price-capacity-optimized picks the pool with the best
# combination of price and interruption risk.
#
# Note: instance_type and instance_market_options are NOT set on the launch
# template — they are controlled entirely by mixed_instances_policy in the ASG.

resource "aws_launch_template" "spot" {
  count       = var.spot_max > 0 ? 1 : 0
  name_prefix = "${var.cluster_name}-spot-"
  image_id    = local.ami_id
  key_name    = aws_key_pair.this.key_name
  # No instance_type — defined per-override in mixed_instances_policy
  # No instance_market_options — set via instances_distribution below

  iam_instance_profile {
    name = var.base_instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    subnet_id                   = var.private_subnet_id
    security_groups             = [var.k8s_nodes_sg_id]
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name                                             = "${var.cluster_name}-worker-spot"
      Role                                             = "worker-spot"
      "k8s.io/cluster-autoscaler/enabled"             = "true"
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "spot" {
  count = var.spot_max > 0 ? 1 : 0

  name                = "${var.cluster_name}-spot-asg"
  vpc_zone_identifier = [var.private_subnet_id]
  min_size            = var.spot_min
  max_size            = var.spot_max
  desired_capacity    = var.spot_min

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0    # 100% spot
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.spot[0].id
        version            = "$Latest"
      }

      # Multiple instance types: if one pool runs out or gets expensive,
      # AWS picks the next best. Add/remove types in spot_instance_types var.
      dynamic "override" {
        for_each = var.spot_instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, {
      Name                                             = "${var.cluster_name}-worker-spot"
      "k8s.io/cluster-autoscaler/enabled"             = "true"
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
