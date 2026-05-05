resource "aws_lb" "k8s_api" {
  name               = "${var.cluster_name}-api-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = [var.private_subnet_id]

  tags = merge(var.tags, { Name = "${var.cluster_name}-api-nlb" })
}

resource "aws_lb_target_group" "k8s_api" {
  name     = "${var.cluster_name}-api-tg"
  port     = 6443
  protocol = "TCP"
  vpc_id   = var.vpc_id

  health_check {
    protocol            = "TCP"
    port                = 6443
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = var.tags
}

resource "aws_lb_listener" "k8s_api" {
  load_balancer_arn = aws_lb.k8s_api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_api.arn
  }
}

resource "aws_lb_target_group_attachment" "control_planes" {
  count            = length(var.control_plane_ids)
  target_group_arn = aws_lb_target_group.k8s_api.arn
  target_id        = var.control_plane_ids[count.index]
  port             = 6443
}
