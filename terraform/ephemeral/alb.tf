# internal ALB + 대상 그룹(gateway · Grafana, ip 타입). 파드 등록은 LBC 의 TargetGroupBinding
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

# Grafana (monitoring) — TargetGroupBinding 은 scripts/aws/addons.sh
resource "aws_lb_target_group" "grafana" {
  name                 = "${local.name}-grafana"
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = 3000
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/api/health"
    port                = "traffic-port"
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

# 운영자 풀(persistent/cognito_ops.tf)로 인증한 요청만 Grafana 로. 인증 쿠키 세션 8시간
#   ALB 가 NAT 로 Cognito 토큰 주소에 나감 (ALB 서브넷 = private, SG 아웃바운드 전체 허용)
#   /oauth2/* : Cognito 콜백 — 이 규칙에 묶어 gateway(기본 동작)로 새지 않게
resource "aws_lb_listener_rule" "grafana" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type  = "authenticate-cognito"
    order = 1
    authenticate_cognito {
      user_pool_arn              = local.p.ops_cognito_user_pool_arn
      user_pool_client_id        = local.p.ops_cognito_alb_client_id
      user_pool_domain           = local.p.ops_cognito_domain_prefix
      on_unauthenticated_request = "authenticate"
      scope                      = "openid email profile"
      session_timeout            = 28800
    }
  }

  action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  condition {
    path_pattern {
      values = ["/grafana", "/grafana/*", "/oauth2/*"]
    }
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
