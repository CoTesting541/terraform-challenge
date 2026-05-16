terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.43.0"
    }
  }
}
provider "aws" {
  region = "eu-north-1" # Your primary region
}

provider "aws" {
  region = "us-east-1"
  alias  = "us_east_1"
}
