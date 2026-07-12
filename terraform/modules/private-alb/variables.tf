# Shared interface first (identical between private-alb and public-nlb), then
# the variables specific to this module. Everything that tunes the service
# itself lives in otel_router_config; load-balancer behaviour lives in
# alb_config.

variable "name" {
  description = "Prefix for everything this module names: load balancer, target groups, cluster, IAM roles, log group. Keep it short — it is embedded in load balancer and target group names, which AWS caps at 32 characters."
  type        = string
  default     = "otel-router"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,25}[a-z0-9])?$", var.name))
    error_message = "name must be 1-27 characters of lowercase letters, digits and hyphens, with no leading or trailing hyphen: the target groups append -http/-grpc and the result must fit AWS's 32-character load balancer and target group name limit."
  }
}

variable "vpc_id" {
  description = "VPC to deploy into. The ALB, target groups and security groups are all created here."
  type        = string
}

variable "task_subnet_ids" {
  description = "Private subnets for the Fargate tasks. Tasks get no public IP, so these subnets need a route to your destinations and to ECR (NAT gateway or VPC endpoints) for image pulls and telemetry egress."
  type        = list(string)

  validation {
    condition     = length(var.task_subnet_ids) > 0
    error_message = "task_subnet_ids must contain at least one subnet."
  }
}

variable "lb_subnet_ids" {
  description = "Subnets for the ALB, in at least two Availability Zones. Public subnets for the default internet-facing ALB; private subnets (typically the task subnets) if you set alb_config.internal = true."
  type        = list(string)

  validation {
    condition     = length(var.lb_subnet_ids) >= 2
    error_message = "lb_subnet_ids must contain at least two subnets in different Availability Zones (an ALB requirement)."
  }
}

variable "image" {
  description = "Full URI of the otel-router image you built and pushed to your own registry, e.g. \"123456789012.dkr.ecr.eu-west-1.amazonaws.com/otel-router:v1\". There is no published image: destinations.yaml is baked in at build time, so the image is necessarily yours."
  type        = string
}

variable "inbound_token_secret_arn" {
  description = "Secrets Manager secret ARN whose value is the INBOUND_TOKEN every sender must present. ECS injects it at container start, so the token never appears in the task definition. Generate it with real randomness, never by hand: openssl rand -hex 32."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:", var.inbound_token_secret_arn))
    error_message = "inbound_token_secret_arn must be a Secrets Manager secret ARN (arn:<partition>:secretsmanager:...)."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource this module creates."
  type        = map(string)
  default     = {}
}

variable "otel_router_config" {
  description = <<-EOT
    Service-level tuning. Everything is optional; the defaults run the router
    on the smallest Fargate size, autoscaling between 1 and 3 tasks.

      cpu / mem                    - Fargate task size (CPU units / MiB); must be a valid Fargate pairing.
      desired_count                - initial task count; autoscaling owns it afterwards.
      cpu_architecture             - "X86_64" or "ARM64"; match the platform you built the image for.
      family                       - task definition family; null uses var.name.
      ecs_cluster_arn              - run in an existing cluster; null creates one with Container Insights enabled.
      security_groups              - bring your own task security groups; null creates one that only admits the ALB.
      extra_environment_variables  - plain env your destinations.yaml references, e.g. BACKEND_ENDPOINT.
      extra_secrets                - env var name => Secrets Manager secret ARN, e.g. BACKEND_AUTH.
      require_env                  - vars the entrypoint must refuse to start without (rendered space-separated into REQUIRE_ENV).
      extra_iam_policies           - policy ARNs attached to the (otherwise empty) task role.
      extra_execution_iam_policies - policy ARNs attached to the execution role, e.g. kms:Decrypt for CMK-encrypted secrets.
      logging                      - CloudWatch retention, or the name of an existing log group to use instead.
      autoscaling                  - min/max task count and CPU/memory target-tracking utilisation targets.
  EOT

  type = object({
    cpu                          = optional(number, 256)
    mem                          = optional(number, 512)
    desired_count                = optional(number, 1)
    cpu_architecture             = optional(string, "X86_64")
    family                       = optional(string, null)
    ecs_cluster_arn              = optional(string, null)
    security_groups              = optional(list(string), null)
    extra_environment_variables  = optional(map(string), {})
    extra_secrets                = optional(map(string), {})
    require_env                  = optional(list(string), [])
    extra_iam_policies           = optional(list(string), [])
    extra_execution_iam_policies = optional(list(string), [])

    logging = optional(object({
      retention_in_days = optional(number, 30)
      log_group_name    = optional(string, null)
    }), {})

    autoscaling = optional(object({
      min_capacity        = optional(number, 1)
      max_capacity        = optional(number, 3)
      cpu_target_value    = optional(number, 80)
      memory_target_value = optional(number, 80)
    }), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["X86_64", "ARM64"], var.otel_router_config.cpu_architecture)
    error_message = "otel_router_config.cpu_architecture must be \"X86_64\" or \"ARM64\"."
  }

  validation {
    condition     = var.otel_router_config.autoscaling.min_capacity <= var.otel_router_config.autoscaling.max_capacity
    error_message = "otel_router_config.autoscaling.min_capacity must not exceed max_capacity."
  }
}

# --- specific to this module -------------------------------------------------

variable "certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listeners. The ALB terminates TLS with it; senders must dial a hostname covered by the certificate's SANs, so point a Route 53 alias or CNAME for that hostname at the ALB DNS name."
  type        = string
}

variable "alb_config" {
  description = <<-EOT
    ALB behaviour.

      internal                - false (default) makes the ALB internet-facing; put public subnets in
                                lb_subnet_ids. Set true only if you want to restrict it to the VPC and
                                anything routed into it (peering, VPN, Direct Connect), in which case
                                lb_subnet_ids may be private subnets. Either way the container stays in
                                a private subnet and the bearer token gates every request.
      https_port              - OTLP/HTTP listener port (senders append /v1/traces etc.).
      grpc_port               - OTLP/gRPC listener port.
      enable_grpc             - false drops the gRPC listener, target group and security group openings.
      allowed_cidrs           - CIDR ranges allowed to reach the listeners.
      allowed_security_groups - security groups allowed to reach the listeners.
      ssl_policy              - TLS negotiation policy for both listeners.
      idle_timeout            - seconds a connection may sit idle. ALBs ignore gRPC (HTTP/2 PING)
                                keepalives — only real data resets the clock — so senders must
                                export within this window or reconnect.
  EOT

  type = object({
    internal                = optional(bool, false)
    https_port              = optional(number, 443)
    grpc_port               = optional(number, 4317)
    enable_grpc             = optional(bool, true)
    allowed_cidrs           = optional(list(string), [])
    allowed_security_groups = optional(list(string), [])
    ssl_policy              = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06")
    idle_timeout            = optional(number, 300)
  })
  default  = {}
  nullable = false

  validation {
    condition     = length(var.alb_config.allowed_cidrs) + length(var.alb_config.allowed_security_groups) > 0
    error_message = "alb_config: set at least one of allowed_cidrs or allowed_security_groups. Both default to empty so the ALB fails closed — with neither set, nothing could ever reach it, so the module refuses loudly at plan time instead of shipping an unreachable endpoint."
  }
}
