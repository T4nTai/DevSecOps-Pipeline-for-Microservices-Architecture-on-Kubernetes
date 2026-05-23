resource "aws_lb" "ingress" {
  name               = "${var.cluster_name}-ingress-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids # all AZs → no single-AZ failure point
  security_groups    = [var.nlb_sg_id]

  # Cross-zone routing balances traffic evenly across workers in all AZs even
  # when AZ traffic is asymmetric. Note: cross-zone has per-GB cost on NLBs.
  enable_cross_zone_load_balancing = true

  # Prevents accidental destroy of the public ingress entry point.
  # Run: terraform state rm module.ingress_nlb.aws_lb.ingress before intentional deletion.
  enable_deletion_protection = true

  # S3 access logs for audit trail — required for DevSecOps compliance.
  # Set nlb_log_bucket to activate. The bucket needs the ELB service account
  # write policy: https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-access-logs.html
  dynamic "access_logs" {
    for_each = var.nlb_log_bucket != "" ? [1] : []
    content {
      bucket  = var.nlb_log_bucket
      prefix  = "${var.cluster_name}-ingress-nlb"
      enabled = true
    }
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-ingress-nlb" })
}

# ── HTTP target group (port 80 → NodePort 30080) ──────────────────────────────
# Health check: HTTP GET / on port 30080.
# Verifies Nginx Ingress Controller is actually responding, not just port-open.

resource "aws_lb_target_group" "http" {
  name     = "${var.cluster_name}-http-tg"
  port     = 30080
  protocol = "TCP"
  vpc_id   = var.vpc_id

  health_check {
    protocol            = "HTTP"
    path                = "/"
    port                = "30080"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 6
    matcher             = "200-404" # Nginx returns 404 for unknown hosts — that's fine
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-http-tg" })
}

# ── HTTPS target group (port 443 → NodePort 30443) ────────────────────────────
# Health check: TCP on port 30443.
# NLB does TCP passthrough for TLS — cannot do HTTP health check on encrypted port.

resource "aws_lb_target_group" "https" {
  name     = "${var.cluster_name}-https-tg"
  port     = 30443
  protocol = "TCP"
  vpc_id   = var.vpc_id

  health_check {
    protocol            = "TCP"
    port                = "30443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-https-tg" })
}

# ── Target group attachments ──────────────────────────────────────────────────
# Using for_each (keyed by instance ID) instead of count so that removing one
# worker from the middle of the list doesn't trigger a full destroy/recreate of
# all attachments (count shifts indices; for_each uses stable keys).

resource "aws_lb_target_group_attachment" "http" {
  for_each = toset(var.worker_ids)

  target_group_arn = aws_lb_target_group.http.arn
  target_id        = each.value
  port             = 30080
}

resource "aws_lb_target_group_attachment" "https" {
  for_each = toset(var.worker_ids)

  target_group_arn = aws_lb_target_group.https.arn
  target_id        = each.value
  port             = 30443
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.ingress.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.ingress.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}
