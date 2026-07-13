# Core inputs first (network, image, the inbound token and TLS secrets), then
# the variables specific to this single-instance EC2 deployment. Everything that
# tunes the container itself lives in router_config, mirroring the sibling
# ecs-fargate module's otel_router_config where the attributes make sense (this
# module runs one container on one box, so there is no cpu/mem/autoscaling or
# cluster to configure).

variable "name" {
  description = "Prefix for everything this module names: the instance, security group, IAM role and instance profile, EIP and alarm. Keep it short and DNS-safe."
  type        = string
  default     = "otel-router"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,25}[a-z0-9])?$", var.name))
    error_message = "name must be 1-27 characters of lowercase letters, digits and hyphens, with no leading or trailing hyphen (kept short to match the sibling ecs-fargate module and to stay tidy in resource names)."
  }
}

variable "vpc_id" {
  description = "VPC to deploy into. The security group is created here."
  type        = string
}

variable "subnet_id" {
  description = "A single PUBLIC subnet for the instance. This module runs one instance, so it takes one subnet — it must have a route to an internet gateway so the Elastic IP is reachable and the box can pull its image from ECR and reach your destinations."
  type        = string
}

variable "image" {
  description = "Full URI of the otel-router image you built and pushed to your own registry, e.g. \"123456789012.dkr.ecr.eu-west-1.amazonaws.com/otel-router:v1\". There is no published image: destinations.yaml is baked in at build time, so the image is necessarily yours. When it is an ECR URI the instance authenticates the pull through its instance profile (see iam.tf); non-ECR registries need their own credentials configured on the host."
  type        = string
}

variable "inbound_token_secret_arn" {
  description = "Secrets Manager secret ARN whose value is the INBOUND_TOKEN every sender must present. The systemd unit fetches it into tmpfs on every (re)start, so the token never lands on the EBS volume. Generate it with real randomness, never by hand: openssl rand -hex 32."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:", var.inbound_token_secret_arn))
    error_message = "inbound_token_secret_arn must be a Secrets Manager secret ARN (arn:<partition>:secretsmanager:...)."
  }
}

variable "tls_cert_secret_arn" {
  description = "Secrets Manager secret ARN holding the PEM certificate (full chain) the container serves on the OTLP ports. The container terminates TLS itself, so this must cover the hostname senders will dial (put that name in the certificate's SANs). Fetched into tmpfs at start; never stored on EBS."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:", var.tls_cert_secret_arn))
    error_message = "tls_cert_secret_arn must be a Secrets Manager secret ARN (arn:<partition>:secretsmanager:...)."
  }
}

variable "tls_key_secret_arn" {
  description = "Secrets Manager secret ARN holding the PEM private key matching tls_cert_secret_arn. Fetched into tmpfs at start, chowned to the container's UID (10001) so it can read the key over the read-only bind mount; never stored on EBS."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:", var.tls_key_secret_arn))
    error_message = "tls_key_secret_arn must be a Secrets Manager secret ARN (arn:<partition>:secretsmanager:...)."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource this module creates."
  type        = map(string)
  default     = {}
}

variable "instance_type" {
  description = "EC2 instance type. The default AMI is x86_64; if you switch to an arm64 instance type (e.g. t4g.small), also supply an arm64 ami_id and build the image for arm64."
  type        = string
  default     = "t3.small"
}

variable "ami_id" {
  description = "AMI to launch. null (default) resolves the latest Amazon Linux 2023 x86_64 AMI from the public SSM parameter. Supply your own only if you need a specific/hardened image — the user-data assumes an AL2023 host (dnf, systemd, amazon-ecr-credential-helper package)."
  type        = string
  default     = null
}

variable "key_name" {
  description = "EC2 key pair name for SSH access. null (default) provisions no SSH key and the security group opens no SSH port — use SSM Session Manager (granted by the instance profile) for a shell instead, which needs no inbound port at all."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. gp3 and encrypted (always). Secrets live only in tmpfs (/run), never on this volume; 20 GiB comfortably holds the OS, Docker and the image."
  type        = number
  default     = 20
}

variable "enable_auto_recovery" {
  description = "Create a CloudWatch alarm that recovers the instance on an EC2 system-status-check failure. Recovery keeps the same instance id and Elastic IP, so the endpoint address survives underlying-hardware failure. Application-level crashes are handled separately by systemd Restart=always and docker's own restart, not by this alarm."
  type        = bool
  default     = true
}

variable "allowed_cidrs" {
  description = "CIDR ranges allowed to reach the OTLP ports. REQUIRED to be non-empty: it defaults to an empty list so the instance fails closed, and the module refuses to plan until you make the explicit choice of who may connect (the bearer token still gates every request, but the network boundary is a deliberate decision). Use [\"0.0.0.0/0\"] to accept any source."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "allowed_cidrs must be non-empty. It defaults to [] so the instance fails closed — an empty list would open nothing and ship an unreachable endpoint — so the module makes you name your senders' CIDRs (or [\"0.0.0.0/0\"]) explicitly."
  }

  validation {
    condition     = alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "allowed_cidrs must all be valid CIDR blocks, e.g. \"203.0.113.0/24\" or \"0.0.0.0/0\"."
  }
}

variable "enable_grpc" {
  description = "true (default) opens the OTLP/gRPC port (4317) and publishes it from the container. false drops that ingress rule and does not publish 4317, leaving only OTLP/HTTP on 4318."
  type        = bool
  default     = true
}

variable "router_config" {
  description = <<-EOT
    Container-level configuration. Everything is optional.

      extra_environment_variables - plain env your destinations.yaml references, e.g. BACKEND_ENDPOINT.
                                    Written into the container's env file on the host at start.
      extra_secrets               - env var name => Secrets Manager secret ARN, e.g. BACKEND_AUTH. The
                                    systemd unit fetches each value into tmpfs at start; values never
                                    land on EBS and never appear in Terraform state or the launch config.
      require_env                 - vars the entrypoint must refuse to start without (rendered
                                    space-separated into REQUIRE_ENV; omitted entirely when empty).
  EOT

  type = object({
    extra_environment_variables = optional(map(string), {})
    extra_secrets               = optional(map(string), {})
    require_env                 = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    # These five names are owned by the module: INBOUND_TOKEN and the three TLS
    # variables are set by the systemd unit, and REQUIRE_ENV is rendered from
    # router_config.require_env. Letting a caller also set them via
    # extra_environment_variables / extra_secrets would silently collide, so
    # reject them at plan time (mirrors the guard in the ecs-fargate module).
    condition = length(setintersection(
      toset(concat(
        keys(var.router_config.extra_environment_variables),
        keys(var.router_config.extra_secrets)
      )),
      toset(["INBOUND_TOKEN", "REQUIRE_ENV", "TLS_ENABLED", "TLS_CERT_FILE", "TLS_KEY_FILE"])
    )) == 0
    error_message = "router_config.extra_environment_variables / extra_secrets must not set INBOUND_TOKEN, REQUIRE_ENV, TLS_ENABLED, TLS_CERT_FILE or TLS_KEY_FILE: the module owns these. Put the inbound token in inbound_token_secret_arn, the PEM pair in tls_cert_secret_arn / tls_key_secret_arn, and list fail-closed vars in router_config.require_env."
  }
}
