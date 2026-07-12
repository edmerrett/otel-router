# Two roles with deliberately different jobs:
#
#   - Execution role: used by the ECS agent BEFORE the container starts — pull
#     the image, create log streams, fetch the Secrets Manager values injected
#     as environment variables.
#   - Task role: assumed by the running container. Created EMPTY on purpose:
#     the router makes no AWS API calls at all. Inbound is OTLP from the ALB,
#     outbound is HTTPS to the destinations in destinations.yaml, and secret
#     injection happens under the execution role before the process exists.
#     It is created anyway so there is a stable place to hang policies if a
#     destination ever needs AWS credentials (e.g. an exporter writing to S3
#     or Kinesis) — attach them via otel_router_config.extra_iam_policies.

data "aws_iam_policy_document" "assume_ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# --- Execution role ----------------------------------------------------------

resource "aws_iam_role" "execution" {
  # name_prefix, not name: IAM role names are account-global (unlike the
  # regional ALB/ECS names), so a fixed name would break deploying this module
  # in a second region with the same var.name.
  name_prefix        = "${var.name}-exec-"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
  tags               = var.tags
}

# Image pulls and CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

locals {
  # Exactly the secrets the task definition references — the inbound token
  # plus every extra_secrets value — and nothing else.
  container_secret_arns = distinct(concat(
    [var.inbound_token_secret_arn],
    values(var.otel_router_config.extra_secrets)
  ))
}

# Least privilege: GetSecretValue on precisely the ARNs the container injects.
# If a secret is encrypted with a customer-managed KMS key (rather than the
# AWS-managed aws/secretsmanager key), the execution role also needs
# kms:Decrypt on that key — pass a policy granting it via
# otel_router_config.extra_execution_iam_policies.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "ReadContainerSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.container_secret_arns
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-container-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# count rather than for_each so policy ARNs created in the same plan (unknown
# until apply) still work.
resource "aws_iam_role_policy_attachment" "execution_extra" {
  count = length(var.otel_router_config.extra_execution_iam_policies)

  role       = aws_iam_role.execution.name
  policy_arn = var.otel_router_config.extra_execution_iam_policies[count.index]
}

# --- Task role ---------------------------------------------------------------

resource "aws_iam_role" "task" {
  # name_prefix for the same account-global reason as the execution role.
  name_prefix        = "${var.name}-task-"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "task_extra" {
  count = length(var.otel_router_config.extra_iam_policies)

  role       = aws_iam_role.task.name
  policy_arn = var.otel_router_config.extra_iam_policies[count.index]
}
