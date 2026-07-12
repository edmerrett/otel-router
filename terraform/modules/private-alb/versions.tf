terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # v6 is the floor shared with the public-nlb sibling module: it lets us
      # use the non-deprecated aws_region data source attributes, and both
      # modules pin identically so a caller can deploy either from one root.
      version = ">= 6.0.0"
    }
  }
}
