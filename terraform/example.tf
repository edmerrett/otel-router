# otel-router on AWS — indicative root module.
#
# This file shows BOTH deployment models side by side so you can see the full
# wiring. In practice you pick ONE:
#
#   modules/private-alb   senders live inside your network; an internal ALB
#                         terminates TLS with an ACM certificate
#   modules/public-nlb    senders dial in over the internet; a public NLB
#                         passes TLS through to the router's own certificate
#
# To adapt: copy this file into your own Terraform root, delete the module
# block you do not need together with its variables and outputs, and keep the
# shared pieces (provider, VPC or your own network IDs, inbound-token secret).
# State backends are deliberately out of scope — add your usual `backend`
# block to the terraform {} below.
#
# Prerequisites (copy-paste commands in README.md next to this file):
#   - the otel-router image built from the repo Dockerfile and pushed to ECR
#   - destination credential secrets created in Secrets Manager
#   - private-alb: a certificate in ACM covering the hostname senders dial
#   - public-nlb:  the PEM certificate and key stored in Secrets Manager

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Inputs. Everything environment-specific enters through these variables so
# the rest of the file works unchanged across accounts and regions.
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "image" {
  description = "Registry URI of the otel-router image you built from the repo Dockerfile and pushed, e.g. \"123456789012.dkr.ecr.us-east-1.amazonaws.com/otel-router:0.156.0\"."
  type        = string
}

variable "certificate_arn" {
  description = "private-alb only: ARN of the ACM certificate served by the internal ALB's HTTPS listeners."
  type        = string
}

variable "tls_cert_secret_arn" {
  description = "public-nlb only: Secrets Manager secret ARN whose value is the PEM certificate (full chain) the router serves."
  type        = string
}

variable "tls_key_secret_arn" {
  description = "public-nlb only: Secrets Manager secret ARN whose value is the matching PEM private key."
  type        = string
}

# Destinations are entirely yours to define in config/destinations.yaml, so
# their endpoints and credentials are yours to name too. The variables below
# wire BOTH destinations the shipped destinations.yaml defines — the OTLP
# backend (BACKEND_*) and the webhook feed (WEBHOOK_*). This is not optional
# padding: the config is baked into the image, its exporters resolve their
# endpoints from these env vars, and the collector refuses to start if any
# referenced variable is unset. Build the image with only the destinations
# you keep, and keep this list in sync — endpoints are plain config,
# credentials come from Secrets Manager as ARNs. Create the credential
# secrets out-of-band (see README.md); that keeps their values out of
# Terraform state.

variable "backend_endpoint" {
  description = "OTLP endpoint of the example backend destination — becomes the BACKEND_ENDPOINT env var referenced by config/destinations.yaml."
  type        = string
}

variable "backend_auth_secret_arn" {
  description = "Secrets Manager secret ARN holding the backend destination's Authorization header value — injected as the BACKEND_AUTH env var."
  type        = string
}

variable "webhook_endpoint" {
  description = "Ingestion URL of the example webhook destination — becomes the WEBHOOK_ENDPOINT env var referenced by config/destinations.yaml."
  type        = string
}

variable "webhook_api_key_secret_arn" {
  description = "Secrets Manager secret ARN holding the webhook destination's API key — injected as the WEBHOOK_API_KEY env var."
  type        = string
}

variable "webhook_secret_secret_arn" {
  description = "Secrets Manager secret ARN holding the webhook destination's feed secret — injected as the WEBHOOK_SECRET env var."
  type        = string
}

locals {
  tags = {
    Project = "otel-router"
  }
}

# ---------------------------------------------------------------------------
# Network. An existing VPC works just as well: delete this module and pass
# your own VPC/subnet IDs straight to the otel-router modules. Tasks need
# private subnets with a route out (NAT here) to pull the image from ECR and
# to reach your destinations; the public-nlb module additionally needs public
# subnets for the internet-facing NLB.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "otel-router"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Inbound token: the bearer token every sender must present. Generated with
# real randomness — mirroring .env.example, never mint tokens by hand — and
# stored in Secrets Manager so ECS injects it at task start. Note the value
# does land in Terraform state via random_password; if your state is not
# treated as secret-grade, create this secret out-of-band instead (README.md
# has the one-liner) and pass its ARN like the destination secrets above.
# ---------------------------------------------------------------------------

resource "random_password" "inbound_token" {
  length  = 64
  special = false # alphanumeric only: header-safe, no shell-escaping surprises
}

resource "aws_secretsmanager_secret" "inbound_token" {
  name = "otel-router/inbound-token"
  tags = local.tags

  # Secrets Manager normally keeps a deleted secret's name reserved for 30
  # days, which would make destroy → re-apply fail on the fixed name above.
  # Zero suits an example you tear up and down; in production prefer the
  # default window so a mistaken destroy is recoverable.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "inbound_token" {
  secret_id     = aws_secretsmanager_secret.inbound_token.id
  secret_string = random_password.inbound_token.result
}

# ---------------------------------------------------------------------------
# Deployment model 1: private VPC. Internal ALB terminates TLS with the ACM
# certificate; the router speaks plaintext behind it, inside the VPC.
# ---------------------------------------------------------------------------

module "otel_router_private" {
  # Consuming from your own repo instead of this checkout? Pin to a release:
  #   source = "github.com/edmerrett/otel-router//terraform/modules/private-alb?ref=<tag>"
  source = "./modules/private-alb"

  # Distinct names are what let both models coexist in one account/region:
  # load balancer, target group, log group and IAM names would all collide on
  # the shared default "otel-router". Keeping only one module? The default is
  # fine — drop this line.
  name = "otel-router-private"

  vpc_id                   = module.vpc.vpc_id
  task_subnet_ids          = module.vpc.private_subnets
  lb_subnet_ids            = module.vpc.private_subnets # internal ALB: private subnets
  image                    = var.image
  inbound_token_secret_arn = aws_secretsmanager_secret.inbound_token.arn
  certificate_arn          = var.certificate_arn
  tags                     = local.tags

  alb_config = {
    # Fail-closed by design: the module refuses to plan unless you name at
    # least one ingress source. Here anything inside the VPC may send;
    # narrow to your senders' security groups via allowed_security_groups.
    allowed_cidrs = [module.vpc.vpc_cidr_block]
  }

  otel_router_config = {
    # Every variable the baked-in destinations.yaml references must be set,
    # or the collector refuses to start. Endpoints are plain env;
    # credentials are injected from Secrets Manager.
    extra_environment_variables = {
      BACKEND_ENDPOINT = var.backend_endpoint
      WEBHOOK_ENDPOINT = var.webhook_endpoint
    }
    extra_secrets = {
      BACKEND_AUTH    = var.backend_auth_secret_arn
      WEBHOOK_API_KEY = var.webhook_api_key_secret_arn
      WEBHOOK_SECRET  = var.webhook_secret_secret_arn
    }
    # Same fail-closed discipline as INBOUND_TOKEN, extended to the
    # destination variables this deployment cannot run without.
    require_env = ["BACKEND_ENDPOINT", "BACKEND_AUTH", "WEBHOOK_ENDPOINT", "WEBHOOK_API_KEY", "WEBHOOK_SECRET"]
  }

  # The token must have a value before the first task tries to start.
  depends_on = [aws_secretsmanager_secret_version.inbound_token]
}

# ---------------------------------------------------------------------------
# Deployment model 2: public / DMZ. Internet-facing NLB passes TCP through;
# the router terminates TLS itself with the PEM pair from Secrets Manager,
# so telemetry stays encrypted end-to-end.
# ---------------------------------------------------------------------------

module "otel_router_public" {
  # Consuming from your own repo instead of this checkout? Pin to a release:
  #   source = "github.com/edmerrett/otel-router//terraform/modules/public-nlb?ref=<tag>"
  source = "./modules/public-nlb"

  # See the note on the private module: distinct names keep the two models
  # from colliding when deployed side by side.
  name = "otel-router-public"

  vpc_id                   = module.vpc.vpc_id
  task_subnet_ids          = module.vpc.private_subnets # tasks stay private
  lb_subnet_ids            = module.vpc.public_subnets  # internet-facing NLB
  image                    = var.image
  inbound_token_secret_arn = aws_secretsmanager_secret.inbound_token.arn
  tls_cert_secret_arn      = var.tls_cert_secret_arn
  tls_key_secret_arn       = var.tls_key_secret_arn
  tags                     = local.tags

  nlb_config = {
    # "Anyone on the internet may reach the OTLP ports" must be an explicit
    # choice, hence no default. The bearer token still gates the telemetry
    # itself, but narrow this to your senders' egress CIDRs if you know them.
    allowed_cidrs = ["0.0.0.0/0"]
  }

  otel_router_config = {
    extra_environment_variables = {
      BACKEND_ENDPOINT = var.backend_endpoint
      WEBHOOK_ENDPOINT = var.webhook_endpoint
    }
    extra_secrets = {
      BACKEND_AUTH    = var.backend_auth_secret_arn
      WEBHOOK_API_KEY = var.webhook_api_key_secret_arn
      WEBHOOK_SECRET  = var.webhook_secret_secret_arn
    }
    require_env = ["BACKEND_ENDPOINT", "BACKEND_AUTH", "WEBHOOK_ENDPOINT", "WEBHOOK_API_KEY", "WEBHOOK_SECRET"]
  }

  depends_on = [aws_secretsmanager_secret_version.inbound_token]
}

# ---------------------------------------------------------------------------
# Endpoints to hand to senders (Authorization: Bearer <inbound token>).
# ---------------------------------------------------------------------------

output "private_otlp_http_endpoint" {
  description = "OTLP/HTTP endpoint on the internal ALB."
  value       = module.otel_router_private.otlp_http_endpoint
}

output "private_otlp_grpc_endpoint" {
  description = "OTLP/gRPC endpoint on the internal ALB (null when gRPC is disabled)."
  value       = module.otel_router_private.otlp_grpc_endpoint
}

output "public_otlp_http_endpoint" {
  description = "OTLP/HTTP endpoint on the public NLB. Production should CNAME a hostname matching the certificate SAN to the NLB DNS name."
  value       = module.otel_router_public.otlp_http_endpoint
}

output "public_otlp_grpc_endpoint" {
  description = "OTLP/gRPC endpoint on the public NLB (null when gRPC is disabled)."
  value       = module.otel_router_public.otlp_grpc_endpoint
}
