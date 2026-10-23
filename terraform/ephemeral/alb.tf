# internal ALB + 대상 그룹(gateway 1개, ip 타입). 파드 등록은 LBC 의 TargetGroupBinding
#   443 : CloudFront VPC origin → HTTPS (ACM ②, persistent/dns.tf)
#   80  : VPC 안 전용 (smoke test · Bastion 터널) — SG 로 노드·Bastion 만 허용, 외부 진입 경로 아님
resource "aws_lb" "internal" {
  name               = local.name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.private_subnets
  idle_timeout       = 60

  drop_invalid_header_fields = true
  xff_header_processing_mode = "append"

  access_logs {
    bucket  = local.p.logs_bucket
    prefix  = "alb"
    enabled = true
  }
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

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.p.alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}
