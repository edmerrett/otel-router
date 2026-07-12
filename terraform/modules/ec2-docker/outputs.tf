output "instance_id" {
  description = "ID of the EC2 instance running the container (for SSM Session Manager, dashboards, alarms)."
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "The Elastic IP — the stable public address of the instance. Point a DNS name matching the certificate's SAN at this address; senders should dial that hostname, not the raw IP (unless the certificate carries an IP SAN)."
  value       = aws_eip.this.public_ip
}

output "otlp_http_endpoint" {
  description = "OTLP/HTTP endpoint (https://<eip>:4318) — the value for OTEL_EXPORTER_OTLP_ENDPOINT with http/protobuf. In production, senders should dial a DNS name that matches the certificate SAN rather than the raw IP."
  value       = "https://${aws_eip.this.public_ip}:4318"
}

output "otlp_grpc_endpoint" {
  description = "OTLP/gRPC endpoint (https://<eip>:4317); null when enable_grpc is false. In production, senders should dial a DNS name that matches the certificate SAN rather than the raw IP."
  value       = var.enable_grpc ? "https://${aws_eip.this.public_ip}:4317" : null
}

output "security_group_id" {
  description = "ID of the instance security group. Reference it from other security groups (or add CIDRs via allowed_cidrs) to admit more senders."
  value       = aws_security_group.this.id
}

output "iam_role_arn" {
  description = "ARN of the instance role (SSM Session Manager, ECR pulls, and GetSecretValue on the referenced secrets)."
  value       = aws_iam_role.this.arn
}

output "eip_allocation_id" {
  description = "Allocation ID of the Elastic IP, for reference from other resources (e.g. a Route 53 record or a shared EIP inventory)."
  value       = aws_eip.this.id
}
