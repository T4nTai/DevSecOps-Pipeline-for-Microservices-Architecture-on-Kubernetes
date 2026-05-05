resource "aws_lb" "ingress" {
  name               = "${var.cluster_name}-ingress-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [var.public_subnet_id]
  security_groups    = [var.nlb_sg_id]

  tags = merge(var.tags, { Name = "${var.cluster_name}-ingress-nlb" })
}

resource "aws_lb_target_group" "http" {
  name     = "${var.cluster_name}-http-tg"
  port     = 30080
  protocol = "TCP"
  vpc_id   = var.vpc_id

  health_check {
    protocol            = "TCP"
    port                = 30080
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-http-tg" })
}

resource "aws_lb_target_group" "https" {
  name     = "${var.cluster_name}-https-tg"
  port     = 30443
  protocol = "TCP"
  vpc_id   = var.vpc_id

  health_check {
    protocol            = "TCP"
    port                = 30443
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-https-tg" })
}

resource "aws_lb_target_group_attachment" "http" {
  count = length(var.worker_ids)

  target_group_arn = aws_lb_target_group.http.arn
  target_id        = var.worker_ids[count.index]
  port             = 30080
}

resource "aws_lb_target_group_attachment" "https" {
  count = length(var.worker_ids)

  target_group_arn = aws_lb_target_group.https.arn
  target_id        = var.worker_ids[count.index]
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
