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

variable "state_bucket" {
  description = "S3 bucket name for Terraform remote state (used to read network layer outputs)"
  type        = string
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
