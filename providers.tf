terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5.0"
    }
  }
  backend "s3" {
    bucket       = "cvprojectremotestate"
    key          = "terraform/state.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "eu-central-1"
}

provider "aws" {
  region = "eu-central-1"
  alias  = "eucentral"
}

provider "aws" {
  region = "us-east-1"
  alias  = "useast"
}