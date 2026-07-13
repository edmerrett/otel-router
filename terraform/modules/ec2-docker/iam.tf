# One instance role, assumed by the EC2 instance through its instance profile.
# It carries exactly three grants:
#
#   - AmazonSSMManagedInstanceCore: lets you open a shell via SSM Session
#     Manager, so no SSH port and no key pair are required (key_name defaults to
#     null and the security group opens no SSH ingress).
#   - AmazonEC2ContainerRegistryReadOnly: lets `docker pull` authenticate to ECR
#     through the credential helper the user-data configures.
#   - An inline policy granting secretsmanager:GetSecretValue on EXACTLY the
#     secrets the box fetches at start (the inbound token, the PEM cert and key,
#     and every extra_secrets value) and nothing else.

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  # name_prefix, not name: IAM role names are account-global, so a fixed name
  # would collide if this module were deployed twice (e.g. a second region)
  # with the same var.name.
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
  tags               = var.tags
}

# Partition-agnostic managed-policy ARNs so the module works in aws, aws-us-gov
# and aws-cn without change.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

locals {
  # Exactly the secrets the box fetches at start — the inbound token, the PEM
  # cert and key, plus every extra_secrets value — deduplicated and nothing
  # else.
  fetched_secret_arns = distinct(concat(
    [
      var.inbound_token_secret_arn,
      var.tls_cert_secret_arn,
      var.tls_key_secret_arn,
    ],
    values(var.router_config.extra_secrets)
  ))
}

# Least privilege: GetSecretValue on precisely the ARNs the instance reads. If a
# secret is encrypted with a customer-managed KMS key (rather than the
# AWS-managed aws/secretsmanager key), the role also needs kms:Decrypt on that
# key — attach a policy granting it to this role out of band (see the README);
# the module keeps its surface to the secrets it can name.
data "aws_iam_policy_document" "read_secrets" {
  statement {
    sid       = "ReadRouterSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.fetched_secret_arns
  }
}

resource "aws_iam_role_policy" "read_secrets" {
  name   = "read-router-secrets"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.this.name
  tags        = var.tags
}
