output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster running the service (created by the module, or the one passed in via otel_router_config.ecs_cluster_arn)."
  value       = local.cluster_arn
}

output "ecs_service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "ARN (with revision) of the active task definition."
  value       = aws_ecs_task_definition.this.arn
}

output "task_security_group_id" {
  description = "ID of the module-created task security group; null when otel_router_config.security_groups was supplied."
  value       = one(aws_security_group.task[*].id)
}

output "lb_security_group_id" {
  description = "ID of the ALB security group. Reference it from other security groups to let additional senders reach the listeners."
  value       = aws_security_group.alb.id
}

output "task_role_arn" {
  description = "ARN of the (intentionally empty) task role."
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ARN of the task execution role (image pulls, logs, secret injection)."
  value       = aws_iam_role.execution.arn
}

output "log_group_name" {
  description = "CloudWatch log group receiving the router's stdout/stderr."
  value       = local.log_group_name
}

output "lb_arn" {
  description = "ARN of the ALB."
  value       = aws_lb.this.arn
}

output "lb_dns_name" {
  description = "DNS name of the ALB. Point a Route 53 alias or CNAME at it for a hostname matching the ACM certificate's SANs."
  value       = aws_lb.this.dns_name
}

output "lb_zone_id" {
  description = "Route 53 hosted zone ID of the ALB, for alias records."
  value       = aws_lb.this.zone_id
}

output "otlp_grpc_endpoint" {
  description = "OTLP/gRPC endpoint (https://<alb dns>:<grpc_port>); null when alb_config.enable_grpc is false. In production, senders should dial a CNAME/alias hostname that matches the certificate SAN rather than the raw ALB DNS name."
  value       = var.alb_config.enable_grpc ? "https://${aws_lb.this.dns_name}:${var.alb_config.grpc_port}" : null
}

output "otlp_http_endpoint" {
  description = "OTLP/HTTP endpoint (https://<alb dns>:<https_port>) — the value for OTEL_EXPORTER_OTLP_ENDPOINT with http/protobuf. In production, senders should dial a CNAME/alias hostname that matches the certificate SAN rather than the raw ALB DNS name."
  value       = "https://${aws_lb.this.dns_name}:${var.alb_config.https_port}"
}
