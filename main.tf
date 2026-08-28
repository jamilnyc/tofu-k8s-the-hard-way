provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# Isolated network for the cluster, separate from any other VPC in the account.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "k8s-hard-way"
  }
}

# Where the 4 instances live; public so each gets a directly reachable public IP.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "k8s-hard-way-public"
  }
}

# Gives the VPC a path to/from the internet, required for public IP connectivity.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "k8s-hard-way"
  }
}

# Directs the subnet's outbound traffic to the internet gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "k8s-hard-way-public"
  }
}

# Wires the route table to the subnet — without this the route table has no effect.
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Detects the operator's current public IP so the security group can scope SSH to it.
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"
}

# Firewall for all 4 instances: SSH only from the operator, open traffic between cluster members.
resource "aws_security_group" "cluster" {
  name        = "k8s-hard-way"
  description = "KTHW cluster: SSH from operator IP, all traffic within the group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from operator current public IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  ingress {
    description = "All traffic between cluster members"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "k8s-hard-way"
  }
}
