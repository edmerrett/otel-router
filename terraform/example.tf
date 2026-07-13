# otel-router on AWS — indicative root module.
#
# This file shows BOTH deployment models side by side so you can see the full
# wiring. In practice you pick ONE, by the infrastructure you already run:
#
#   modules/ecs-fargate   a managed ECS Fargate service behind an ALB that
#                         terminates TLS with an ACM certificate; the router
#                         runs plaintext in a private subnet behind it. For
#                         teams already on ECS.
#   modules/ec2-docker    a single EC2 host running the container via Docker,
#                         directly internet-facing, the container terminating
#                         TLS itself with a PEM pair from Secrets Manager. For
#                         teams not on ECS.
#
# The axis is the infrastructure you run, not who may reach the endpoint. In
# the ECS case the container is always private and only the ALB is exposed; in
# the EC2 case the container IS the box, reached on its Elastic IP. Either way
# senders present a bearer token the router itself enforces, so TLS termination
# never means accepting unauthenticated telemetry. See README.md for the full
# comparison.
#
# To adapt: copy this file into your own Terraform root, delete the module
# block you do not need together with its variables and outputs, and keep the
# shared pieces (provider, VPC or your own network IDs, inbound-token secret).
# State backends are deliberately out of scope — add your usual `backend`
# block to the terraform {} below.
#
# Existing infrastructure: this file provisions everything greenfield (VPC,
# ECS cluster, EC2 instance), but every piece is bring-your-own. Deploy into a
# VPC you already run by deleting the `module "vpc"` block and passing your own
# vpc_id / subnet IDs. Deploy the ECS service into a cluster you already run by
# setting var.existing_ecs_cluster_arn (see its definition below) — otherwise
# the module creates its own cluster. Same pattern for the log group, task
# security group, and IAM (all default to module-created, all overridable via
# otel_router_config).
#
# Prerequisites (copy-paste commands in README.md next to this file):
#   - the otel-router image built from the repo Dockerfile and pushed to ECR
#   - destination credential secrets created in Secrets Manager
#   - ecs-fargate: a certificate in ACM covering the hostname senders dial
#   - ec2-docker:  the PEM certificate and key stored in Secrets Manager

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

# Cluster placement (ecs-fargate only). Leave null and the module creates its
# OWN Fargate cluster (named after the module's `name`, Container Insights on)
# and deploys the service into it — zero extra setup. Set this to an existing
# cluster ARN (arn:aws:ecs:<region>:<acct>:cluster/<name>) and the module skips
# cluster creation and registers the service into yours instead. Fargate tasks
# need no EC2 capacity in that cluster; it is purely where the service is
# grouped. Look one up with: aws ecs list-clusters
variable "existing_ecs_cluster_arn" {
  description = "ecs-fargate only: ARN of an existing ECS cluster to deploy the router service into. Leave null to have the module create its own cluster."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "ecs-fargate only: ARN of the ACM certificate served by the ALB's HTTPS listeners."
  type        = string
}

variable "tls_cert_secret_arn" {
  description = "ec2-docker only: Secrets Manager secret ARN whose value is the PEM certificate (full chain) the container serves."
  type        = string
}

variable "tls_key_secret_arn" {
  description = "ec2-docker only: Secrets Manager secret ARN whose value is the matching PEM private key."
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
# your own VPC/subnet IDs straight to the otel-router modules. The Fargate
# tasks need private subnets with a route out (NAT here) to pull the image
# from ECR and reach your destinations; the ec2-docker instance sits in a
# public subnet, reaching ECR and your destinations directly over its Elastic
# IP.
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
# stored in Secrets Manager so both models inject it at container start. Note
# the value does land in Terraform state via random_password; if your state is
# not treated as secret-grade, create this secret out-of-band instead
# (README.md has the one-liner) and pass its ARN like the destination secrets
# above.
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
# Deployment model 1 — ecs-fargate. A managed Fargate service behind an ALB
# that terminates TLS with the ACM certificate; the router speaks plaintext
# behind it, in a private subnet. The ALB is internet-facing (set
# alb_config.internal = true, and move lb_subnet_ids to private subnets, for a
# VPC-only endpoint). For teams already on ECS.
# ---------------------------------------------------------------------------

module "otel_router_ecs" {
  # Consuming from your own repo instead of this checkout? Pin to a release:
  #   source = "github.com/edmerrett/otel-router//terraform/modules/ecs-fargate?ref=<tag>"
  source = "./modules/ecs-fargate"

  # Distinct names are what let both models coexist in one account/region:
  # load balancer, target group, log group and IAM names would all collide on
  # the shared default "otel-router". Keeping only one module? The default is
  # fine — drop this line.
  name = "otel-router-ecs"

  vpc_id                   = module.vpc.vpc_id
  task_subnet_ids          = module.vpc.private_subnets
  lb_subnet_ids            = module.vpc.public_subnets # internet-facing ALB: public subnets
  image                    = var.image
  inbound_token_secret_arn = aws_secretsmanager_secret.inbound_token.arn
  certificate_arn          = var.certificate_arn
  tags                     = local.tags

  alb_config = {
    # Internet-facing by default. Fail-closed: the module refuses to plan
    # unless you name at least one ingress source. "Anyone may reach the
    # ACM-terminated listeners" is an explicit choice — narrow to your
    # senders' CIDRs, or set internal = true for a VPC-only ALB. The bearer
    # token still gates every request regardless.
    allowed_cidrs = ["0.0.0.0/0"]
  }

  otel_router_config = {
    # null => this module creates its own cluster; set var.existing_ecs_cluster_arn
    # to deploy into a cluster you already run instead.
    ecs_cluster_arn = var.existing_ecs_cluster_arn

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
# Deployment model 2 — ec2-docker. A single EC2 host runs the container via
# Docker, directly internet-facing on its Elastic IP; the container terminates
# TLS itself with the PEM pair from Secrets Manager, so telemetry stays
# encrypted end to end. For teams not on ECS.
# ---------------------------------------------------------------------------

module "otel_router_ec2" {
  # Consuming from your own repo instead of this checkout? Pin to a release:
  #   source = "github.com/edmerrett/otel-router//terraform/modules/ec2-docker?ref=<tag>"
  source = "./modules/ec2-docker"

  # See the note on the ecs module: distinct names keep the two models from
  # colliding when deployed side by side.
  name = "otel-router-ec2"

  vpc_id = module.vpc.vpc_id
  # A single instance lives in ONE subnet; a public one so its Elastic IP is
  # internet-reachable and it can pull from ECR and reach destinations without
  # a NAT gateway.
  subnet_id                = element(module.vpc.public_subnets, 0)
  image                    = var.image
  inbound_token_secret_arn = aws_secretsmanager_secret.inbound_token.arn
  tls_cert_secret_arn      = var.tls_cert_secret_arn
  tls_key_secret_arn       = var.tls_key_secret_arn
  tags                     = local.tags

  # "Anyone on the internet may reach the OTLP ports" must be an explicit
  # choice, hence the module's empty default and this required list. The bearer
  # token still gates the telemetry itself, but narrow this to your senders'
  # egress CIDRs if you know them.
  allowed_cidrs = ["0.0.0.0/0"]

  router_config = {
    # Every variable the baked-in destinations.yaml references must be set,
    # or the collector refuses to start. Endpoints are plain env; credentials
    # are fetched from Secrets Manager into tmpfs at container start.
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

output "ecs_otlp_http_endpoint" {
  description = "OTLP/HTTP endpoint on the ALB."
  value       = module.otel_router_ecs.otlp_http_endpoint
}

output "ecs_otlp_grpc_endpoint" {
  description = "OTLP/gRPC endpoint on the ALB (null when gRPC is disabled)."
  value       = module.otel_router_ecs.otlp_grpc_endpoint
}

output "ec2_otlp_http_endpoint" {
  description = "OTLP/HTTP endpoint on the EC2 host. Production should point a DNS name matching the certificate SAN at the Elastic IP and hand senders that hostname."
  value       = module.otel_router_ec2.otlp_http_endpoint
}

output "ec2_otlp_grpc_endpoint" {
  description = "OTLP/gRPC endpoint on the EC2 host (null when gRPC is disabled)."
  value       = module.otel_router_ec2.otlp_grpc_endpoint
}

output "ec2_public_ip" {
  description = "Elastic IP of the EC2 host. Point a DNS name matching the certificate SAN at it; senders dial that hostname, not the raw IP."
  value       = module.otel_router_ec2.public_ip
}
