terraform {
  required_version = "~> 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    region       = "eu-central-1"
    bucket       = "sajad-aws-s3-bucket"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "arn:aws:kms:eu-central-1:598520881431:key/c028cd8f-4a67-42ae-9054-bdf6c7999fde"
    key          = "terraform/aws/state-files/example2/terraform.tfstate"
    profile      = "default"
  }
}

provider "aws" {
  shared_credentials_files = ["~/.aws/credentials"]
  profile                  = "default"
  region                   = "eu-central-1"
}