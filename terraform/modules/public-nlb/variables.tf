# ---------------------------------------------------------------------------
# Shared interface - identical in modules/private-alb and modules/public-nlb,
# so the two deployment models are drop-in swaps for each other.
# ---------------------------------------------------------------------------

variable "name" {
  description = "Prefix for every named resource this module creates (load balancer, target groups, security groups, IAM roles, log group). Keep it short: it is embedded in load balancer and target group names, which AWS caps at 32 characters."
  type        = string
  default     = "otel-router"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,25}[a-z0-9])?$", var.name))
    error_message = "name must be 1-27 characters of lowercase alphanumerics and hyphens, starting and ending with an alphanumeric: the target groups append -http/-grpc and the result must fit AWS's 32-character load balancer and target group name limit."
  }
}

variable "vpc_id" {
  description = "VPC in which to create the NLB, target groups and security groups."
  type        = string
}

variable "task_subnet_ids" {
  description = "PRIVATE subnets for the Fargate tasks. Tasks get no public IP, so these subnets need a route to the OTLP destinations and to ECR / Secrets Manager / CloudWatch Logs (NAT gateway or VPC endpoints)."
  type        = list(string)

  validation {
    condition     = length(var.task_subnet_ids) > 0
    error_message = "task_subnet_ids must contain at least one subnet."
  }
}

variable "lb_subnet_ids" {
  description = "PUBLIC subnets for the internet-facing NLB, one per AZ it should serve from. (With nlb_config.internal = true, private subnets instead.)"
  type        = list(string)

  validation {
    condition     = length(var.lb_subnet_ids) > 0
    error_message = "lb_subnet_ids must contain at least one subnet."
  }
}

variable "image" {
  description = "Full URI of the otel-router image you built from this repo's Dockerfile and pushed to your own registry, e.g. \"123456789012.dkr.ecr.eu-west-1.amazonaws.com/otel-router:v1\". There is no published image."
  type        = string
}

variable "inbound_token_secret_arn" {
  description = "Secrets Manager secret ARN whose value is the INBOUND_TOKEN bearer token every sender must present. The entrypoint fails closed without it. Generate the token with real randomness (openssl rand -hex 32)."
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
  description = "Everything tunable about the ECS side of the deployment. All attributes are optional; the defaults run a small self-contained deployment (own cluster, own task security group, own log group). See the README inputs table for per-attribute documentation."
  type = object({
    cpu                          = optional(number, 256)        # Fargate CPU units for the task
    mem                          = optional(number, 512)        # task memory in MiB
    desired_count                = optional(number, 1)          # initial task count (autoscaling owns it after creation)
    cpu_architecture             = optional(string, "X86_64")   # or "ARM64"; must match how the image was built
    family                       = optional(string, null)       # task definition family; null => var.name
    ecs_cluster_arn              = optional(string, null)       # existing cluster; null => module creates one with container insights
    security_groups              = optional(list(string), null) # task SGs; null => module creates one admitting only the NLB SG
    extra_environment_variables  = optional(map(string), {})    # plain env your destinations.yaml references, e.g. BACKEND_ENDPOINT
    extra_secrets                = optional(map(string), {})    # env var name => Secrets Manager secret ARN, e.g. BACKEND_AUTH
    require_env                  = optional(list(string), [])   # rendered space-separated into REQUIRE_ENV (env var omitted when empty)
    extra_iam_policies           = optional(list(string), [])   # policy ARNs attached to the task role
    extra_execution_iam_policies = optional(list(string), [])   # policy ARNs attached to the execution role (e.g. kms:Decrypt for CMK-encrypted secrets)
    logging = optional(object({
      retention_in_days = optional(number, 30)
      log_group_name    = optional(string, null) # existing log group; null => module creates "/ecs/<name>"
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
    error_message = "otel_router_config.cpu_architecture must be \"X86_64\" or \"ARM64\" (the values Fargate's runtime_platform accepts)."
  }

  validation {
    condition     = var.otel_router_config.autoscaling.min_capacity <= var.otel_router_config.autoscaling.max_capacity
    error_message = "otel_router_config.autoscaling.min_capacity must not exceed max_capacity."
  }
}

# ---------------------------------------------------------------------------
# public-nlb extras: the TLS material the container terminates with, and NLB
# behaviour. The NLB never holds a certificate - its listeners are plain TCP
# and the TLS session runs end-to-end between the sender and the container.
# ---------------------------------------------------------------------------

variable "tls_cert_secret_arn" {
  description = "Secrets Manager secret ARN whose VALUE is the PEM certificate (full chain) the router serves on 4317/4318. Its SAN must match the hostname senders dial - in production, CNAME that hostname to the NLB DNS name. Rotation requires a new deployment; see the README."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:", var.tls_cert_secret_arn))
    error_message = "tls_cert_secret_arn must be a Secrets Manager secret ARN (arn:<partition>:secretsmanager:...)."
  }
}

variable "tls_key_secret_arn" {
  description = "Secrets Manager secret ARN whose VALUE is the PEM private key matching tls_cert_secret_arn."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:", var.tls_key_secret_arn))
    error_message = "tls_key_secret_arn must be a Secrets Manager secret ARN (arn:<partition>:secretsmanager:...)."
  }
}

variable "tls_init_image" {
  description = "Image for the tls-init init container that copies the PEMs from Secrets Manager onto the shared task volume. Pulled from public ECR by default so Fargate needs no Docker Hub credentials."
  type        = string
  default     = "public.ecr.aws/docker/library/busybox:1.37"
}

variable "nlb_config" {
  description = "NLB behaviour. allowed_cidrs has no default on purpose: opening a public OTLP endpoint to the whole internet must be an explicit choice, so pass [\"0.0.0.0/0\"] yourself if that is what you want."
  type = object({
    internal      = optional(bool, false)      # true => private NLB in private lb_subnet_ids instead of internet-facing
    enable_grpc   = optional(bool, true)       # listener + target group for OTLP/gRPC on 4317
    allowed_cidrs = optional(list(string), []) # REQUIRED non-empty: source CIDRs allowed to reach the NLB
    cross_zone    = optional(bool, true)       # spread connections across tasks in every AZ
  })
  default  = {}
  nullable = false

  validation {
    condition     = length(var.nlb_config.allowed_cidrs) > 0
    error_message = "nlb_config.allowed_cidrs must not be empty: with no allowed sources nothing can reach the NLB, so the module fails closed, loudly, at plan time. Exposing the endpoint to the whole internet must be an explicit choice - pass [\"0.0.0.0/0\"] if that is really what you want."
  }

  validation {
    condition     = alltrue([for c in var.nlb_config.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in nlb_config.allowed_cidrs must be a valid CIDR block, e.g. \"203.0.113.0/24\"."
  }
}
