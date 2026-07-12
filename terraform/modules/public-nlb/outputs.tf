output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster running the service (the module-created one, or the one passed in via otel_router_config.ecs_cluster_arn)."
  value       = local.cluster_arn
}

output "ecs_service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "ARN (with revision) of the registered task definition."
  value       = aws_ecs_task_definition.this.arn
}

output "task_security_group_id" {
  description = "ID of the module-created task security group, or null when the caller supplied otel_router_config.security_groups."
  value       = local.create_task_sg ? aws_security_group.task[0].id : null
}

output "lb_security_group_id" {
  description = "ID of the NLB security group. Reference it from your own task security group if you bring one - it is the only source the tasks need to admit."
  value       = aws_security_group.nlb.id
}

output "task_role_arn" {
  description = "ARN of the (deliberately empty) task role."
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ARN of the task execution role (image pull, logs, secrets)."
  value       = aws_iam_role.execution.arn
}

output "log_group_name" {
  description = "CloudWatch log group receiving the otel-router and tls-init streams."
  value       = local.log_group_name
}

output "lb_arn" {
  description = "ARN of the Network Load Balancer."
  value       = aws_lb.this.arn
}

output "lb_dns_name" {
  description = "DNS name of the Network Load Balancer."
  value       = aws_lb.this.dns_name
}

output "lb_zone_id" {
  description = "Route 53 hosted zone ID of the NLB, for alias records."
  value       = aws_lb.this.zone_id
}

output "otlp_grpc_endpoint" {
  description = "OTLP/gRPC endpoint (https because the container serves TLS); null when gRPC is disabled. In production, CNAME a real hostname matching the certificate's SAN to the NLB DNS name and hand senders that hostname instead - TLS verification against the raw NLB name will fail otherwise."
  value       = var.nlb_config.enable_grpc ? "https://${aws_lb.this.dns_name}:4317" : null
}

output "otlp_http_endpoint" {
  description = "OTLP/HTTP endpoint (https because the container serves TLS). In production, CNAME a real hostname matching the certificate's SAN to the NLB DNS name and hand senders that hostname instead - TLS verification against the raw NLB name will fail otherwise."
  value       = "https://${aws_lb.this.dns_name}:4318"
}
