terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.53.0"
    }
  }

  required_version = ">= 1.15.7"

  # Remote state in the S3 bucket created by ./bootstrap (named
  # greencity-tfstate-<account-id>). The bucket name is account-specific, so it is
  # supplied at init time via partial backend config — never hardcoded:
  #   terraform init -backend-config="bucket=greencity-tfstate-<YOUR-ACCOUNT-ID>"
  # use_lockfile = native S3 state locking (no DynamoDB needed, Terraform >= 1.11).
  backend "s3" {
    key          = "greencity/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}