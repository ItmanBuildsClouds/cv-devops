terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
provider "aws" {
  region = "eu-central-1"
  alias = "eucentral"
}
provider "aws" {
  region = "us-east-1"
  alias = "useast"
}