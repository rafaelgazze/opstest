provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "network"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
