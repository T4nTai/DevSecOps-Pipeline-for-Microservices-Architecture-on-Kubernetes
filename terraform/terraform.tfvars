aws_region   = "ap-southeast-1"
cluster_name = "devsecops-k8s"

control_plane_instance_type = "t3.small"
worker_instance_type        = "t3.large"

admin_username  = "ubuntu"
public_key_path = "~/.ssh/id_ed25519.pub"

# Replace with your own IP for better security: curl ifconfig.me
allowed_ssh_cidr = "116.111.184.81/32"

k8s_version = "1.29"
