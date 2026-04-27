terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "rcoauth2ast-terraform-state"
    key            = "frontend/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "rcoauth2ast-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {}
