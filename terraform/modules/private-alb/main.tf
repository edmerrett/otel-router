# Private deployment: senders inside the network dial an INTERNAL ALB that
# terminates TLS with an ACM certificate; behind it, otel-router tasks on
# Fargate speak plaintext. Transport and auth stay independent layers — the
# bearer-token check still happens inside the router, so stripping TLS at the
# ALB never means accepting unauthenticated telemetry.
#
# Layout: data sources and locals, security groups, load balancer, target
# groups, listeners, logs, cluster, task definition, service, autoscaling.
# IAM roles live in iam.tf.

data "aws_region" "current" {}

locals {
  # "null means the module creates it" switches, resolved once so every later
  # reference reads the same way.
  create_cluster = var.otel_router_config.ecs_cluster_arn == null
  create_task_sg = var.otel_router_config.security_groups == null
  create_logs    = var.otel_router_config.logging.log_group_name == null

  cluster_arn = local.create_cluster ? aws_ecs_cluster.this[0].arn : var.otel_router_config.ecs_cluster_arn

  # Application Auto Scaling addresses the service by cluster NAME, but only
  # the ARN is available in both the created and bring-your-own cases, so the
  # name is derived from it (arn:aws:ecs:<region>:<account>:cluster/<name>).
  cluster_name = element(split("/", local.cluster_arn), 1)

  task_family             = coalesce(var.otel_router_config.family, var.name)
  log_group_name          = local.create_logs ? aws_cloudwatch_log_group.this[0].name : var.otel_router_config.logging.log_group_name
  task_security_group_ids = local.create_task_sg ? [aws_security_group.task[0].id] : var.otel_router_config.security_groups

  # Listener ports senders may dial, and the container ports the ALB must
  # reach. 13133 appears task-side because the HTTP1 target group health
  # checks the always-plain-HTTP health endpoint directly (see the target
  # groups below for why the gRPC one cannot).
  alb_ingress_ports  = var.alb_config.enable_grpc ? [var.alb_config.https_port, var.alb_config.grpc_port] : [var.alb_config.https_port]
  task_ingress_ports = var.alb_config.enable_grpc ? [4317, 4318, 13133] : [4318, 13133]

  # Plain environment for the container. Iterating a map yields keys in
  # lexical order, so the rendered task definition is stable across runs.
  # REQUIRE_ENV mirrors the entrypoint contract: space-separated var names to
  # fail closed on, omitted entirely when there is nothing extra to enforce.
  container_environment = concat(
    [for k, v in var.otel_router_config.extra_environment_variables : { name = k, value = v }],
    length(var.otel_router_config.require_env) > 0 ? [{ name = "REQUIRE_ENV", value = join(" ", var.otel_router_config.require_env) }] : []
  )

  # ECS fetches these with the EXECUTION role and injects them at container
  # start; secret values never appear in the task definition.
  container_secrets = concat(
    [{ name = "INBOUND_TOKEN", valueFrom = var.inbound_token_secret_arn }],
    [for k, v in var.otel_router_config.extra_secrets : { name = k, valueFrom = v }]
  )
}

# --- Security groups ---------------------------------------------------------

# ALB security group: only the senders you declared may reach the listeners.
# Both source lists (CIDRs and security groups) feed every listener port.
# Egress stays open so the ALB can reach the tasks on their container ports
# and run health checks against them.
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Senders allowed to reach the otel-router internal ALB"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = local.alb_ingress_ports

    content {
      description     = "OTLP senders, port ${ingress.value}"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      cidr_blocks     = var.alb_config.allowed_cidrs
      security_groups = var.alb_config.allowed_security_groups
    }
  }

  egress {
    description      = "To the tasks (forwarding and health checks)"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

# Task security group, created only when the caller does not bring their own.
# The ONLY ingress source is the ALB security group: nothing else in the VPC
# can talk to the tasks directly. Egress stays open because the tasks must
# reach your destinations and pull the image from ECR.
resource "aws_security_group" "task" {
  count = local.create_task_sg ? 1 : 0

  name_prefix = "${var.name}-task-"
  description = "otel-router tasks: ingress from the ALB only"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = local.task_ingress_ports

    content {
      description     = "From the ALB only, port ${ingress.value}"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [aws_security_group.alb.id]
    }
  }

  egress {
    description      = "Destinations and ECR image pulls"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-task" })

  lifecycle {
    create_before_destroy = true
  }
}

# --- Load balancer -----------------------------------------------------------

resource "aws_lb" "this" {
  name                       = var.name
  load_balancer_type         = "application"
  internal                   = var.alb_config.internal
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.lb_subnet_ids
  drop_invalid_header_fields = true

  # ALBs do not answer HTTP/2 PING frames, so gRPC keepalives never reset the
  # idle clock — only real data does. The module default is 300s (vs AWS's
  # 60s) so senders on a relaxed export schedule keep their connections; raise
  # alb_config.idle_timeout if yours flush even less often.
  idle_timeout = var.alb_config.idle_timeout

  tags = var.tags
}

# OTLP/HTTP target group. The container port is plaintext 4318 (TLS ended at
# the ALB), and the health check goes to the collector's health_check
# extension on 13133 — a port that stays plain HTTP by design, so this probe
# needs no token and no TLS.
resource "aws_lb_target_group" "http" {
  name                 = "${var.name}-http"
  port                 = 4318
  protocol             = "HTTP"
  protocol_version     = "HTTP1"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    port     = 13133
    protocol = "HTTP"
    path     = "/"
    matcher  = "200"
  }

  tags = var.tags
}

# OTLP/gRPC target group. protocol_version = "GRPC" makes the ALB speak
# cleartext h2c gRPC to the task (the collector accepts plaintext gRPC by
# default). Changing protocol_version forces a new target group.
#
# The health check MUST stay on the traffic port: a GRPC-protocol_version
# target group frames its probe as a gRPC request, so it cannot check the
# plain-HTTP health endpoint on 13133 like the HTTP1 group above. The probe
# carries no bearer token, so the collector answers UNAUTHENTICATED (16) — or
# UNIMPLEMENTED (12) for the default /AWS.ALB/healthcheck path — and
# matcher = "0-99" accepts any gRPC status code: a gRPC-framed answer of any
# kind proves the server is up, which is all a health check needs. Real
# telemetry is still rejected without the token.
resource "aws_lb_target_group" "grpc" {
  count = var.alb_config.enable_grpc ? 1 : 0

  name                 = "${var.name}-grpc"
  port                 = 4317
  protocol             = "HTTP"
  protocol_version     = "GRPC"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    port     = "traffic-port"
    protocol = "HTTP"
    path     = "/AWS.ALB/healthcheck"
    matcher  = "0-99"
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.alb_config.https_port
  protocol          = "HTTPS"
  ssl_policy        = var.alb_config.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }

  tags = var.tags
}

# gRPC requires an HTTPS listener on the ALB; the same ACM certificate covers
# both listeners.
resource "aws_lb_listener" "grpc" {
  count = var.alb_config.enable_grpc ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = var.alb_config.grpc_port
  protocol          = "HTTPS"
  ssl_policy        = var.alb_config.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grpc[0].arn
  }

  tags = var.tags
}

# --- Logs and cluster --------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  count = local.create_logs ? 1 : 0

  name              = "/ecs/${var.name}"
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

# --- Task definition ---------------------------------------------------------

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

  container_definitions = jsonencode([
    {
      name      = "otel-router"
      image     = var.image
      essential = true

      # 4317 OTLP/gRPC, 4318 OTLP/HTTP, 13133 health (always plain HTTP).
      portMappings = [
        { containerPort = 4317, protocol = "tcp" },
        { containerPort = 4318, protocol = "tcp" },
        { containerPort = 13133, protocol = "tcp" }
      ]

      environment = local.container_environment
      secrets     = local.container_secrets

      # The image is FROM scratch and the collector writes nothing to disk
      # (in-memory queues only), so the root filesystem can be sealed shut.
      readonlyRootFilesystem = true

      # Mirrors the Dockerfile HEALTHCHECK. The image ships a single busybox
      # binary with NO applet symlinks, so every utility must be invoked as
      # "/bin/busybox <applet>" — a bare "wget" does not exist in the image.
      healthCheck = {
        command     = ["CMD", "/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:13133/"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      logConfiguration = {
        logDriver = "awslogs"
        # On Fargate, awslogs requires all three options to be set.
        options = {
          "awslogs-group"         = local.log_group_name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "otel-router"
        }
      }
    }
  ])

  tags = var.tags
}

# --- Service -----------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = local.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.otel_router_config.desired_count
  launch_type     = "FARGATE"

  # New tasks get 60s to pass the container and target group health checks;
  # with the circuit breaker, a deployment that can never go healthy rolls
  # back instead of flapping forever.
  health_check_grace_period_seconds = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.task_subnet_ids
    security_groups  = local.task_security_group_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.http.arn
    container_name   = "otel-router"
    container_port   = 4318
  }

  dynamic "load_balancer" {
    for_each = aws_lb_target_group.grpc

    content {
      target_group_arn = load_balancer.value.arn
      container_name   = "otel-router"
      container_port   = 4317
    }
  }

  # Autoscaling owns desired_count after creation; without this, every plan
  # would fight the scaler back to the initial value.
  lifecycle {
    ignore_changes = [desired_count]
  }

  # Target groups must be attached to a listener before ECS can register
  # targets into them.
  depends_on = [
    aws_lb_listener.https,
    aws_lb_listener.grpc
  ]

  tags = var.tags
}

# --- Autoscaling -------------------------------------------------------------

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
