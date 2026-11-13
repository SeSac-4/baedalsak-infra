# ---------- CloudWatch 알람 → SNS alerts(persistent) → Discord (Lambda notify, + ALERT_EMAILS 메일) ----------
#   임계값은 v1 기본값 (운영하며 조정 — 설계상 "알람 임계값"은 후순위 결정)
locals {
  alarms = {
    alb-5xx = {
      namespace = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", stat = "Sum", op = "GreaterThanThreshold", threshold = 10
      dims      = { LoadBalancer = aws_lb.internal.arn_suffix }
    }
    gateway-unhealthy = {
      namespace = "AWS/ApplicationELB", metric = "UnHealthyHostCount", stat = "Maximum", op = "GreaterThanThreshold", threshold = 0
      dims      = { LoadBalancer = aws_lb.internal.arn_suffix, TargetGroup = aws_lb_target_group.gateway.arn_suffix }
    }
    rds-cpu = {
      namespace = "AWS/RDS", metric = "CPUUtilization", stat = "Average", op = "GreaterThanThreshold", threshold = 80
      dims      = { DBInstanceIdentifier = aws_db_instance.this.identifier }
    }
    rds-storage = {
      namespace = "AWS/RDS", metric = "FreeStorageSpace", stat = "Minimum", op = "LessThanThreshold", threshold = 2147483648 # 2GiB
      dims      = { DBInstanceIdentifier = aws_db_instance.this.identifier }
    }
    # 연결 한도: max_connections 79 − 관리자 예약 3 = 앱 76. 90% ≈ 68 (AWS 권장 알람 90~95%). 최악 계산값 60 (5 × (HPA 2 + surge 1) × 풀 4) — #52
    #   인스턴스 클래스를 바꾸면 한도가 바뀌므로 같이 조정 (small 은 약 180)
    rds-connections = {
      namespace = "AWS/RDS", metric = "DatabaseConnections", stat = "Maximum", op = "GreaterThanThreshold", threshold = 68
      dims      = { DBInstanceIdentifier = aws_db_instance.this.identifier }
    }
    redis-memory = {
      namespace = "AWS/ElastiCache", metric = "DatabaseMemoryUsagePercentage", stat = "Maximum", op = "GreaterThanThreshold", threshold = 80 # noeviction → 가득 차면 쓰기 실패
      dims      = { CacheClusterId = tolist(aws_elasticache_replication_group.this.member_clusters)[0] }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each            = local.alarms
  alarm_name          = "${local.name}-${each.key}"
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.stat
  comparison_operator = each.value.op
  threshold           = each.value.threshold
  dimensions          = each.value.dims
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.p.alerts_topic_arn] # OK 전환 메일은 안 보냄 — 매일 켤 때 INSUFFICIENT_DATA→OK 로 5통씩 옴
}
