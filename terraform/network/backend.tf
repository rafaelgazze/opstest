terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Configured via -backend-config at init time:
    #   bucket       = "suchapp-terraform-state-<account_id>"
    #   key          = "suchapp/<env>/network.tfstate"
    #   region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
