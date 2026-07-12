# IAM for the otel-router task. Two roles with sharply different jobs:
#
#  - The EXECUTION role is what the ECS agent uses to set the task up: pull
#    the image, create log streams, and fetch the Secrets Manager values it
#    injects as container secrets (the inbound token, the TLS PEMs, and any
#    extra_secrets).
#  - The TASK role is what the running containers could use to call AWS APIs.
#    The router never calls AWS - it only receives OTLP and forwards it over
#    HTTPS - so this role is deliberately empty. Attach extra_iam_policies
#    only if you add a destination that genuinely needs AWS access.

locals {
  # Every Secrets Manager ARN the task definition references: the inbound
  # token, the TLS certificate and key, and each extra_secrets value. The
  # execution role may read exactly these and nothing else.
  task_secret_arns = distinct(concat(
    [
      var.inbound_token_secret_arn,
      var.tls_cert_secret_arn,
      var.tls_key_secret_arn,
    ],
    values(var.otel_router_config.extra_secrets),
  ))
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

# Baseline execution permissions: ECR image pull + CloudWatch Logs writes.
resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secrets access is scoped to the exact ARNs in the task definition. Note:
# if any of these secrets is encrypted with a customer-managed KMS key
# (rather than the default aws/secretsmanager key), the execution role also
# needs kms:Decrypt on that key - pass a policy granting it via
# otel_router_config.extra_execution_iam_policies.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "ReadTaskSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.task_secret_arns
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-task-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

resource "aws_iam_role_policy_attachment" "execution_extra" {
  count = length(var.otel_router_config.extra_execution_iam_policies)

  role       = aws_iam_role.execution.name
  policy_arn = var.otel_router_config.extra_execution_iam_policies[count.index]
}

# Task role: created empty on purpose. The router's job is receiving OTLP
# and forwarding it over HTTPS; it makes no AWS API calls at runtime, so an
# empty role is the least-privilege answer. It exists (rather than being
# omitted) so extra_iam_policies has somewhere to attach and so future needs
# do not require a task definition replacement.
resource "aws_iam_role" "task" {
  name_prefix        = "${var.name}-task-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "task_extra" {
  count = length(var.otel_router_config.extra_iam_policies)

  role       = aws_iam_role.task.name
  policy_arn = var.otel_router_config.extra_iam_policies[count.index]
}
