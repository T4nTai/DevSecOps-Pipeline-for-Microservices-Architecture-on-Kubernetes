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
}

resource "aws_key_pair" "this" {
  key_name   = "${var.cluster_name}-key"
  public_key = file(var.public_key_path)
  tags       = var.tags
}

# ── Bastion ───────────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  count                  = var.create_bastion ? 1 : 0
  ami                    = data.aws_ami.ubuntu.id
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

resource "aws_instance" "control_plane" {
  count                  = var.control_plane_count
  ami                    = local.ami_id
  instance_type          = var.control_plane_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.k8s_nodes_sg_id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = var.instance_profile_name

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

# ── On-demand workers — stateful (Harbor, Vault) ──────────────────────────────

resource "aws_instance" "worker" {
  count                  = var.worker_count
  ami                    = local.ami_id
  instance_type          = var.worker_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.k8s_nodes_sg_id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = var.instance_profile_name

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name                                             = "${var.cluster_name}-worker-${count.index + 1}"
    Role                                             = "worker"
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })
}

# ── Burst worker — pre-joined, stopped when idle ─────────────────────────────

resource "aws_instance" "burst_worker" {
  count                  = var.burst_worker_count
  ami                    = local.ami_id
  instance_type          = var.worker_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.k8s_nodes_sg_id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = var.instance_profile_name

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = false  # preserve disk when stopped
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-burst-worker"
    Role = "burst-worker"
  })

  lifecycle {
    ignore_changes = [ami]  # don't recreate if AMI updates
  }
}

# ── Spot workers — stateless (Jenkins agents, SonarQube) ─────────────────────

resource "aws_launch_template" "spot" {
  count         = var.spot_max > 0 ? 1 : 0
  name_prefix   = "${var.cluster_name}-spot-"
  image_id      = local.ami_id
  instance_type = var.worker_instance_type
  key_name      = aws_key_pair.this.key_name

  iam_instance_profile {
    name = var.instance_profile_name
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

  instance_market_options {
    market_type = "spot"
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

  launch_template {
    id      = aws_launch_template.spot[0].id
    version = "$Latest"
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
