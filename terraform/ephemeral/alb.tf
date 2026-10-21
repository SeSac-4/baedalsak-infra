# internal ALB + 대상 그룹(gateway 1개, ip 타입). 파드 등록은 LBC 의 TargetGroupBinding
resource "aws_lb" "internal" {
  name               = local.name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.private_subnets
  idle_timeout       = 60

  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "gateway" {
  name                 = "${local.name}-gw"
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = 8080
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/actuator/health/readiness"
    port                = "8081"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# 도메인·ACM ② 전: HTTP 80 으로 바로 전달 / 인증서가 있으면 80 → 443 리다이렉트
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = var.alb_certificate_arn == "" ? [1] : []
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.gateway.arn
    }
  }

  dynamic "default_action" {
    for_each = var.alb_certificate_arn == "" ? [] : [1]
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.alb_certificate_arn == "" ? 0 : 1
  load_balancer_arn = aws_lb.internal.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}
