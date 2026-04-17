variable "environment" {
  description = "Environment name (dev, sta, acc, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "sta", "acc", "prod"], var.environment)
    error_message = "Environment must be one of: dev, sta, acc, prod."
  }
}

variable "region" {
  description = "AWS region to deploy to"
  type        = string
}

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "suchapp"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == 3
    error_message = "Exactly 3 public subnet CIDRs required (one per AZ)."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == 3
    error_message = "Exactly 3 private subnet CIDRs required (one per AZ)."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the application"
  type        = string
  default     = "t3.micro"
}

variable "asg_min" {
  description = "Minimum number of instances in each ASG"
  type        = number
  default     = 1
}

variable "asg_max" {
  description = "Maximum number of instances in each ASG"
  type        = number
  default     = 2
}

variable "asg_desired" {
  description = "Desired number of instances in the active ASG"
  type        = number
  default     = 2
}

variable "ami_id" {
  description = "AMI ID for the application (built by Packer)"
  type        = string
}

variable "app_port" {
  description = "Port the Spring Boot application listens on"
  type        = number
  default     = 8080
}

variable "nat_gateway_count" {
  description = "Number of NAT Gateways (1 for dev/cost, 3 for prod/HA)"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3], var.nat_gateway_count)
    error_message = "NAT gateway count must be 1 or 3."
  }
}
