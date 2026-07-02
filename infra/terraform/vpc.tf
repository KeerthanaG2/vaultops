# vpc.tf
# Core network for VaultOps. Public subnets host the EC2 instance running the
# audit API (needs a public IP to be reachable for the demo). Private subnets
# host RDS (database should never be directly internet-reachable).
# No NAT Gateway is used anywhere — NAT Gateways cost ~$0.045/hr even when idle,
# which breaks the zero-cost requirement. RDS doesn't need outbound internet
# access for normal operation (it's reached *from* the EC2 instance, it doesn't
# need to reach *out* to the internet itself).

resource "aws_vpc" "vaultops" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "vaultops-vpc"
  }
}

# Internet Gateway — required so the public subnets (and the EC2 instance in
# them) can reach the internet, and so you can SSH into EC2 from your laptop.
resource "aws_internet_gateway" "vaultops" {
  vpc_id = aws_vpc.vaultops.id

  tags = {
    Name = "vaultops-igw"
  }
}

# --- Public subnets ---
# These host resources that need a public IP / internet route, like the EC2
# instance running the FastAPI audit API.

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.vaultops.id
  cidr_block               = "10.0.1.0/24"
  availability_zone        = "ap-south-1a"
  map_public_ip_on_launch  = true

  tags = {
    Name = "vaultops-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.vaultops.id
  cidr_block               = "10.0.2.0/24"
  availability_zone        = "ap-south-1b"
  map_public_ip_on_launch  = true

  tags = {
    Name = "vaultops-public-b"
  }
}

# --- Private subnets ---
# These host RDS. No route to the internet — RDS is reached only from inside
# the VPC (i.e. from the EC2 instance in the public subnet, via its security
# group rule), and never needs to initiate outbound internet connections.

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.vaultops.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "ap-south-1a"

  tags = {
    Name = "vaultops-private-a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.vaultops.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "ap-south-1b"

  tags = {
    Name = "vaultops-private-b"
  }
}

# --- Public route table ---
# Routes all outbound traffic (0.0.0.0/0) through the Internet Gateway.
# Associated with both public subnets so resources there get internet access.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vaultops.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vaultops.id
  }

  tags = {
    Name = "vaultops-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --- Private route table ---
# Intentionally has NO route to the internet (no NAT Gateway, no IGW route).
# Only the default local route (within 10.0.0.0/16) exists implicitly.
# This is what keeps the architecture free — and it's also more secure,
# since RDS has zero path to the public internet.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vaultops.id

  tags = {
    Name = "vaultops-private-rt"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# --- Outputs ---
# Needed in later days (Day 3) to wire EC2, RDS, and security groups to the
# correct subnets.

output "vpc_id" {
  description = "ID of the VaultOps VPC"
  value       = aws_vpc.vaultops.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (EC2 goes here)"
  value       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (RDS goes here)"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}