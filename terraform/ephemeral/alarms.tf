# ---------- CloudWatch 알람 → SNS alerts(persistent) → 메일 (ALERT_EMAILS) ----------
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
  alarm_actions       = [local.p.alerts_topic_arn]
  ok_actions          = [local.p.alerts_topic_arn]
}
