variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use for authentication"
  type        = string
  default     = "terraform-personal"
}

variable "instance_type" {
  description = "EC2 instance type for all 4 machines"
  type        = string
  default     = "t3.medium"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for the subnet and instances"
  type        = string
  default     = "us-east-1a"
}

variable "machines" {
  description = "Machine name to static private IP mapping"
  type        = map(string)
  default = {
    jumpbox = "10.0.1.10"
    server  = "10.0.1.11"
    node-0  = "10.0.1.12"
    node-1  = "10.0.1.13"
  }
}

variable "root_volume_sizes" {
  description = "Root EBS volume size (GB) per machine name"
  type        = map(number)
  default = {
    jumpbox = 10
    server  = 20
    node-0  = 20
    node-1  = 20
  }
}
