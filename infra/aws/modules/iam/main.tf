# ── Base role ─────────────────────────────────────────────────────────────────
# All K8s nodes: EBS CSI driver + Cluster Autoscaler discovery.
# Assigned to: control-plane, apps-worker, spot ASG.

resource "aws_iam_role" "base" {
  name = "${var.cluster_name}-base-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(var.tags, { Name = "${var.cluster_name}-base-node-role" })
}

resource "aws_iam_role_policy_attachment" "base_ebs_csi" {
  role       = aws_iam_role.base.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── Shared: Cluster Autoscaler managed policy ──────────────────────────────────
# Both base and stateful roles need identical CA permissions.
# Extracted into one aws_iam_policy to avoid duplicate code and simplify future
# updates (change once → both roles pick it up automatically).
# Resource = "*" is intentional: CA must enumerate all ASGs in the account to
# discover node groups — it cannot be scoped to a specific resource ARN.
resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${var.cluster_name}-cluster-autoscaler"
  description = "Allows K8s Cluster Autoscaler to discover and resize ASGs."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeInstanceTypes"
      ]
      Resource = "*" # CA needs account-wide ASG discovery — cannot scope further
    }]
  })
}

resource "aws_iam_role_policy_attachment" "base_cluster_autoscaler" {
  role       = aws_iam_role.base.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# cert-manager Route53 DNS-01 — on ALL nodes because cert-manager can be
# scheduled on any node. ChangeResourceRecordSets is scoped to hostedzone/*.
resource "aws_iam_role_policy" "base_cert_manager_route53" {
  name = "${var.cluster_name}-base-cert-manager-route53"
  role = aws_iam_role.base.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:GetChange",
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = [
          "arn:aws:route53:::change/*",
          "arn:aws:route53:::hostedzone/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "base" {
  name = "${var.cluster_name}-base-node-profile"
  role = aws_iam_role.base.name
}

# ── Stateful role ──────────────────────────────────────────────────────────────
# On-demand worker(s) running stateful workloads: Vault (KMS unseal), Harbor,
# cert-manager (Route53 DNS-01). Inherits base policies via separate attachments.

resource "aws_iam_role" "stateful" {
  name = "${var.cluster_name}-stateful-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(var.tags, { Name = "${var.cluster_name}-stateful-node-role" })
}

resource "aws_iam_role_policy_attachment" "stateful_ebs_csi" {
  role       = aws_iam_role.stateful.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "stateful_cluster_autoscaler" {
  role       = aws_iam_role.stateful.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# Vault KMS auto-unseal — only on stateful nodes running Vault
resource "aws_iam_role_policy" "stateful_vault_kms" {
  count = var.vault_kms_key_arn != "" ? 1 : 0
  name  = "${var.cluster_name}-stateful-vault-kms"
  role  = aws_iam_role.stateful.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
      Resource = var.vault_kms_key_arn
    }]
  })
}

# cert-manager Route53 DNS-01 challenge — only on stateful nodes running cert-manager
resource "aws_iam_role_policy" "stateful_cert_manager_route53" {
  name = "${var.cluster_name}-stateful-cert-manager-route53"
  role = aws_iam_role.stateful.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:GetChange",
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = [
          "arn:aws:route53:::change/*",
          "arn:aws:route53:::hostedzone/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "stateful" {
  name = "${var.cluster_name}-stateful-node-profile"
  role = aws_iam_role.stateful.name
}
