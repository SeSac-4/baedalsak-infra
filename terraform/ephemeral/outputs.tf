output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "rds_host" {
  value = aws_db_instance.this.address
}

output "mq_host" {
  value = local.mq_host
}

output "mq_console_url" {
  value = aws_mq_broker.this.instances[0].console_url
}

output "redis_host" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "target_group_arn" {
  value = aws_lb_target_group.gateway.arn
}

output "alb_dns" {
  value = aws_lb.internal.dns_name
}

output "bastion_instance_id" {
  value = aws_instance.bastion.id
}
