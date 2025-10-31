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
}
provider "aws" {
  region = "eu-central-1"
}
provider "aws" {
  region = "us-east-1"
  alias = "acm"
}