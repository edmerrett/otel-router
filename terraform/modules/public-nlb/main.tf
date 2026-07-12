# public-nlb: DMZ / internet-facing deployment of otel-router on ECS Fargate.
#
# The Network Load Balancer listens on plain TCP and passes the TLS byte
# stream through untouched; otel-router terminates TLS itself with a
# certificate delivered from Secrets Manager by the tls-init init container
# (see the task definition below). Senders therefore get end-to-end TLS all
# the way into the container - the load balancer never holds a key and never
# sees plaintext telemetry.
#
# Layout: data/locals, security groups, NLB + target groups + listeners,
# logs, cluster, task definition, service, autoscaling.

data "aws_region" "current" {}

locals {
  # Cluster: the caller's, or one this module creates (aws_ecs_cluster below).
  create_cluster = var.otel_router_config.ecs_cluster_arn == null
  cluster_arn    = local.create_cluster ? aws_ecs_cluster.this[0].arn : var.otel_router_config.ecs_cluster_arn

  # Application Auto Scaling addresses an ECS service by cluster NAME, which
  # is the final segment of the cluster ARN (arn:...:cluster/<name>).
  cluster_name = element(split("/", local.cluster_arn), 1)

  # Task security group: the caller's list, or one this module creates that
  # admits traffic from the NLB security group only.
  create_task_sg          = var.otel_router_config.security_groups == null
  task_security_group_ids = local.create_task_sg ? [aws_security_group.task[0].id] : var.otel_router_config.security_groups

  create_log_group = var.otel_router_config.logging.log_group_name == null
  log_group_name   = coalesce(var.otel_router_config.logging.log_group_name, "/ecs/${var.name}")

  task_family = coalesce(var.otel_router_config.family, var.name)
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

# NLB security group. AWS only allows security groups on a Network Load
# Balancer when they are attached AT CREATION - an NLB created without one
# can never gain one later, so this module always creates the NLB with its
# SG. Having the SG is what lets the task SG below admit traffic "from the
# NLB SG" by reference (which keeps working even with client IP preservation)
# instead of opening the task ports to the client CIDRs directly.
resource "aws_security_group" "nlb" {
  name_prefix = "${var.name}-nlb-"
  description = "otel-router NLB: OTLP over TLS from allowed sources"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.nlb_config.enable_grpc ? [1] : []
    content {
      description = "OTLP/gRPC over TLS (passed through to the task)"
      from_port   = 4317
      to_port     = 4317
      protocol    = "tcp"
      cidr_blocks = var.nlb_config.allowed_cidrs
    }
  }

  ingress {
    description = "OTLP/HTTP over TLS (passed through to the task)"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = var.nlb_config.allowed_cidrs
  }

  # NLB health checks towards the targets are subject to these OUTBOUND
  # rules, so egress must stay open.
  egress {
    description = "All outbound (target health checks and return traffic)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-nlb" })

  # A security group referenced by other rules cannot be destroyed in place;
  # create the replacement first so rule references never dangle.
  lifecycle {
    create_before_destroy = true
  }
}

# Task security group, created only when the caller did not bring their own.
# The OTLP ports and the health check port admit ONLY the NLB security group;
# nothing else in the VPC can reach the tasks. 13133 must be open to the NLB
# because the target groups health check it directly (plain HTTP - see the
# target group comment).
resource "aws_security_group" "task" {
  count = local.create_task_sg ? 1 : 0

  name_prefix = "${var.name}-task-"
  description = "otel-router tasks: OTLP and health checks from the NLB only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "OTLP/gRPC (TLS) from the NLB"
    from_port       = 4317
    to_port         = 4317
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  ingress {
    description     = "OTLP/HTTP (TLS) from the NLB"
    from_port       = 4318
    to_port         = 4318
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  ingress {
    description     = "Health checks from the NLB (always plain HTTP)"
    from_port       = 13133
    to_port         = 13133
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  # Open egress: image pull (ECR), Secrets Manager, CloudWatch Logs, and the
  # user-defined OTLP destinations the router forwards to.
  egress {
    description = "All outbound (image pull, AWS APIs, destinations)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-task" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Network Load Balancer: plain TCP listeners = TLS passthrough
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = var.name
  load_balancer_type = "network"
  internal           = var.nlb_config.internal
  subnets            = var.lb_subnet_ids

  # Attached at creation on purpose - see the aws_security_group.nlb comment.
  security_groups = [aws_security_group.nlb.id]

  # With cross-zone on, every NLB node can reach tasks in every AZ, so one
  # AZ's unhealthy tasks never blackhole that AZ's share of traffic. It costs
  # a little inter-AZ data transfer; turn it off via nlb_config if that
  # matters more to you than even spreading.
  enable_cross_zone_load_balancing = var.nlb_config.cross_zone

  tags = merge(var.tags, { Name = var.name })
}

# The target groups are plain TCP (the TLS stream is opaque to the NLB), but
# their health checks are HTTP against port 13133: the collector's
# health_check extension stays plain HTTP even in TLS mode BY DESIGN,
# precisely so load balancers can probe it without trusting the router's
# certificate. NLB target groups support exactly this: TCP traffic with an
# HTTP health check on an overridden port.
resource "aws_lb_target_group" "http" {
  name                 = "${var.name}-http"
  port                 = 4318
  protocol             = "TCP"
  target_type          = "ip" # mandatory for Fargate (awsvpc): tasks register by ENI IP
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    protocol            = "HTTP"
    port                = 13133
    path                = "/"
    matcher             = "200-399"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, { Name = "${var.name}-http" })
}

resource "aws_lb_target_group" "grpc" {
  count = var.nlb_config.enable_grpc ? 1 : 0

  name                 = "${var.name}-grpc"
  port                 = 4317
  protocol             = "TCP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    protocol            = "HTTP"
    port                = 13133
    path                = "/"
    matcher             = "200-399"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, { Name = "${var.name}-grpc" })
}

# Plain TCP listeners: no certificate here, on purpose. The TLS session runs
# end-to-end between the sender and the container's own certificate.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 4318
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }

  tags = var.tags
}

resource "aws_lb_listener" "grpc" {
  count = var.nlb_config.enable_grpc ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 4317
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grpc[0].arn
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Logs and cluster (each created only when the caller did not bring one)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  count = local.create_log_group ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.otel_router_config.logging.retention_in_days
  tags              = var.tags
}

resource "aws_ecs_cluster" "this" {
  count = local.create_cluster ? 1 : 0

  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Task definition: tls-init (init container) + otel-router
#
# Why two containers: the router image is FROM scratch and runs as UID 10001
# with no writable path anywhere, and Fargate bind-mount volumes come up
# root-owned. Only a root container can write the PEMs into the shared volume
# and chown them to the router's UID - so a tiny busybox init container does
# exactly that, exits, and the router starts only after it succeeded.
# ---------------------------------------------------------------------------

locals {
  # Environment for the router container. Maps iterate in key order, so the
  # rendered list is stable across plans.
  router_environment = concat(
    # Destination endpoints the baked-in destinations.yaml references, e.g.
    # BACKEND_ENDPOINT. Credentials belong in extra_secrets, not here.
    [for k, v in var.otel_router_config.extra_environment_variables : { name = k, value = v }],

    # REQUIRE_ENV extends the entrypoint's fail-closed startup check to the
    # listed variables. Omit the env var entirely when there is nothing to
    # require - absent reads cleaner in the console than present-but-empty.
    length(var.otel_router_config.require_env) == 0 ? [] : [
      { name = "REQUIRE_ENV", value = join(" ", var.otel_router_config.require_env) },
    ],

    # The router terminates TLS itself. tls-init puts these files in place
    # before this container is allowed to start, and the entrypoint fails
    # closed rather than silently falling back to plaintext if they are
    # missing or unreadable.
    [
      { name = "TLS_ENABLED", value = "true" },
      { name = "TLS_CERT_FILE", value = "/otel-tls/tls.crt" },
      { name = "TLS_KEY_FILE", value = "/otel-tls/tls.key" },
    ],
  )

  # INBOUND_TOKEN first (the one variable the router itself requires), then
  # the user-defined destination credentials.
  router_secrets = concat(
    [{ name = "INBOUND_TOKEN", valueFrom = var.inbound_token_secret_arn }],
    [for k, v in var.otel_router_config.extra_secrets : { name = k, valueFrom = v }],
  )

  # tls-init: root init container that materialises the PEM secrets onto the
  # shared task volume. ECS injects the PEMs as environment variables from
  # Secrets Manager; the command writes them out with a trailing newline,
  # hands ownership to the router's UID, and locks the key down to
  # owner-read. essential=false means "exiting 0 is fine" - it is a one-shot
  # job, not a long-running sidecar.
  tls_init_container = {
    name      = "tls-init"
    image     = var.tls_init_image
    essential = false
    user      = "0" # must be root to write and chown the root-owned Fargate volume

    command = [
      "sh", "-c",
      "set -e; printf \"%s\\n\" \"$TLS_CERT_PEM\" > /otel-tls/tls.crt; printf \"%s\\n\" \"$TLS_KEY_PEM\" > /otel-tls/tls.key; chown 10001:10001 /otel-tls/tls.crt /otel-tls/tls.key; chmod 0444 /otel-tls/tls.crt; chmod 0400 /otel-tls/tls.key",
    ]

    secrets = [
      { name = "TLS_CERT_PEM", valueFrom = var.tls_cert_secret_arn },
      { name = "TLS_KEY_PEM", valueFrom = var.tls_key_secret_arn },
    ]

    mountPoints = [
      { sourceVolume = "otel-tls", containerPath = "/otel-tls", readOnly = false },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.log_group_name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "tls-init"
      }
    }
  }

  router_container = {
    name      = "otel-router"
    image     = var.image
    essential = true

    portMappings = [
      { containerPort = 4317, protocol = "tcp" },  # OTLP/gRPC (TLS)
      { containerPort = 4318, protocol = "tcp" },  # OTLP/HTTP (TLS)
      { containerPort = 13133, protocol = "tcp" }, # health check (always plain HTTP)
    ]

    environment = local.router_environment
    secrets     = local.router_secrets

    # The image is FROM scratch and nothing in it writes to the root
    # filesystem. The TLS volume below is a mount, so it is unaffected.
    readonlyRootFilesystem = true

    # Read-only view of the volume tls-init populated. dependsOn SUCCESS
    # means the router starts only after tls-init exited 0, so the
    # entrypoint's fail-closed TLS file check can never race the write.
    mountPoints = [
      { sourceVolume = "otel-tls", containerPath = "/otel-tls", readOnly = true },
    ]
    dependsOn = [
      { containerName = "tls-init", condition = "SUCCESS" },
    ]

    # The image ships a busybox binary but NO applet symlinks, so every
    # utility must be invoked as "/bin/busybox <applet>". Port 13133 is the
    # collector's health_check extension and stays plain HTTP in TLS mode.
    healthCheck = {
      command     = ["CMD", "/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:13133/"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.log_group_name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "otel-router"
      }
    }
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.task_family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.otel_router_config.cpu
  memory                   = var.otel_router_config.mem
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.otel_router_config.cpu_architecture
  }

  # Ephemeral volume shared between tls-init (writes) and the router (reads).
  # No host_path or efs configuration = Fargate-local scratch storage that
  # lives and dies with the task; the PEMs never touch anything durable.
  volume {
    name = "otel-tls"
  }

  container_definitions = jsonencode([
    local.tls_init_container,
    local.router_container,
  ])

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = local.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.otel_router_config.desired_count
  launch_type     = "FARGATE"

  # A fresh task needs image pulls, the tls-init run and the collector's
  # startPeriod before load balancer health checks should count against it.
  health_check_grace_period_seconds = 60

  # Roll back automatically instead of relaunching a broken revision forever.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.task_subnet_ids
    security_groups  = local.task_security_group_ids
    assign_public_ip = false # tasks live in private subnets; the NLB is the only public face
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.http.arn
    container_name   = "otel-router"
    container_port   = 4318
  }

  dynamic "load_balancer" {
    for_each = var.nlb_config.enable_grpc ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.grpc[0].arn
      container_name   = "otel-router"
      container_port   = 4317
    }
  }

  # Autoscaling owns desired_count after creation; without this, every apply
  # would fight the scaler back to the initial value.
  lifecycle {
    ignore_changes = [desired_count]
  }

  # awslogs fails the task launch if the log group does not exist yet, and
  # the container definitions reference it only by name (no implicit
  # dependency). Also wait for the listeners so targets register into
  # target groups that are actually routable.
  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_lb_listener.http,
    aws_lb_listener.grpc,
  ]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Autoscaling: target tracking on CPU and memory
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${local.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.otel_router_config.autoscaling.min_capacity
  max_capacity       = var.otel_router_config.autoscaling.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.otel_router_config.autoscaling.cpu_target_value

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.name}-memory"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.otel_router_config.autoscaling.memory_target_value

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}
