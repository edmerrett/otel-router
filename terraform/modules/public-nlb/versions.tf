terraform {
  # optional() object attribute defaults (used throughout variables.tf)
  # need terraform >= 1.3; we require 1.5 to match the rest of this repo.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # v6 is the floor shared with the private-alb sibling module: it lets us
      # use the non-deprecated aws_region data source attributes, and both
      # modules pin identically so a caller can deploy either from one root.
      # (NLB security-group support, which this module depends on, has been in
      # the provider since 5.13.0 — see main.tf for why it must be attached at
      # creation time.)
      version = ">= 6.0.0"
    }
  }
}
