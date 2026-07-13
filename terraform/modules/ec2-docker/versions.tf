terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # v6 floor: it lets us use the non-deprecated aws_region data source
      # attributes. The sibling ecs-fargate module pins the same floor so a
      # caller can deploy either from one root.
      version = ">= 6.0.0"
    }
  }
}
