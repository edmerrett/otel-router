# EC2 deployment: a single instance runs the otel-router container via Docker,
# directly internet-facing on an Elastic IP. Unlike the ecs-fargate module,
# there is no load balancer — the CONTAINER terminates the sender's TLS itself,
# using the PEM cert/key you keep in Secrets Manager, and enforces the inbound
# bearer token as always. This is the module for teams that do not run ECS.
#
# How the box comes up: cloud-init (templates/user-data.sh.tftpl) installs
# Docker and the AWS CLI, wires ECR credential-helper auth for image pulls, and
# installs a systemd unit. That unit's ExecStart script fetches INBOUND_TOKEN,
# the destination secrets and the PEM cert/key from Secrets Manager into /run
# (tmpfs) on EVERY start, then runs the container with TLS enabled and the certs
# bind-mounted read-only. Nothing secret is ever written to the EBS volume, so
# rotating a secret is just a restart.
#
# Layout: data sources and locals, security group, instance, EIP, auto-recovery
# alarm. IAM (instance role + profile) lives in iam.tf.

data "aws_partition" "current" {}
data "aws_region" "current" {}

# Latest Amazon Linux 2023 x86_64 AMI, resolved from the public SSM parameter,
# only when the caller did not pin an ami_id. AL2023 is required by the
# user-data (dnf, systemd, the amazon-ecr-credential-helper package).
data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ami_id = coalesce(var.ami_id, one(data.aws_ssm_parameter.al2023[*].value))

  # The registry host is the part before the first "/" of the image URI. For an
  # ECR image this is the host the credential helper must be wired to (see the
  # user-data). Derived here so both the template and any future reference read
  # the same value.
  registry_host = split("/", var.image)[0]
}

# --- Security group ----------------------------------------------------------

# Only the senders you declared may reach the OTLP ports. 4318 (OTLP/HTTP) is
# always open; 4317 (OTLP/gRPC) only when enable_grpc. 13133 (health) is
# deliberately NOT exposed — health is local to the box (the container's own
# Docker healthcheck), never a public surface. Egress stays open so the
# instance can pull the image from ECR, reach Secrets Manager and SSM, and send
# telemetry to your destinations.
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "Senders allowed to reach the otel-router instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "OTLP/HTTP senders"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  dynamic "ingress" {
    for_each = var.enable_grpc ? [1] : []

    content {
      description = "OTLP/gRPC senders"
      from_port   = 4317
      to_port     = 4317
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidrs
    }
  }

  egress {
    description      = "ECR pulls, Secrets Manager, SSM and destination egress"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

# --- Instance ----------------------------------------------------------------

resource "aws_instance" "this" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  # Public subnet: the instance needs a routable address at boot to pull its
  # image and fetch secrets before the EIP is associated. The Elastic IP below
  # replaces this auto-assigned address as the stable public endpoint.
  associate_public_ip_address = true

  # IMDSv2 only: require a session token for the metadata service, which blocks
  # the SSRF-style credential theft that IMDSv1 allows.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
    tags        = merge(var.tags, { Name = var.name })
  }

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    region                   = data.aws_region.current.region
    image                    = var.image
    registry_host            = local.registry_host
    inbound_token_secret_arn = var.inbound_token_secret_arn
    tls_cert_secret_arn      = var.tls_cert_secret_arn
    tls_key_secret_arn       = var.tls_key_secret_arn
    extra_env                = var.router_config.extra_environment_variables
    extra_secrets            = var.router_config.extra_secrets
    require_env              = join(" ", var.router_config.require_env)
    enable_grpc              = var.enable_grpc
  })

  # Re-provision the instance when the rendered user-data changes (new image
  # tag, new secret ARN, gRPC toggled): the script only runs on first boot, so
  # a change to it must replace the box to take effect.
  user_data_replace_on_change = true

  # Do not replace the instance every time the AL2023 SSM parameter bumps to a
  # newer AMI. Without this, a routine `terraform apply` weeks later would
  # rebuild the running box out from under live traffic just because AWS
  # published a new AL2023 image. To adopt a new AMI deliberately, bump ami_id
  # or `terraform taint` this resource.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(var.tags, { Name = var.name })
}

# --- Elastic IP --------------------------------------------------------------

# A stable public address that survives instance stop/start and auto-recovery,
# so the hostname senders dial (a DNS record pointed here, matching the cert
# SAN) never has to change.
resource "aws_eip" "this" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = var.name })
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this.id
}

# --- Auto-recovery alarm -----------------------------------------------------

# Recovers the instance on UNDERLYING-HARDWARE failure (a failed EC2 system
# status check), keeping the same instance id and the same Elastic IP so the
# endpoint address is preserved. This is distinct from application crashes,
# which systemd (Restart=always) and Docker's own restart handle in-place
# without touching the instance.
resource "aws_cloudwatch_metric_alarm" "auto_recovery" {
  count = var.enable_auto_recovery ? 1 : 0

  alarm_name          = "${var.name}-auto-recovery"
  alarm_description   = "Recover the otel-router instance on a system status check failure (preserves instance id and EIP)."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    InstanceId = aws_instance.this.id
  }

  alarm_actions = ["arn:${data.aws_partition.current.partition}:automate:${data.aws_region.current.region}:ec2:recover"]

  tags = var.tags
}
