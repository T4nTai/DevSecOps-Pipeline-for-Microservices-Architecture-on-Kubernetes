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

resource "aws_key_pair" "this" {
  key_name   = "${var.cluster_name}-key"
  public_key = file(var.public_key_path)

  tags = var.tags
}

resource "aws_instance" "bastion" {
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

resource "aws_instance" "control_plane" {
  count                  = var.control_plane_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.control_plane_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.k8s_nodes_sg_id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = var.instance_profile_name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-control-plane-${count.index + 1}"
    Role = "control-plane"
  })
}

resource "aws_instance" "worker" {
  count                  = var.worker_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.worker_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.k8s_nodes_sg_id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = var.instance_profile_name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-worker-${count.index + 1}"
    Role = "worker"
  })
}
