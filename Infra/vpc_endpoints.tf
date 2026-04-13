
# =========================================
# SECURITY GROUP FOR INTERFACE ENDPOINTS
# All interface endpoints share one SG.
# Only needs to accept HTTPS (443) from within the VPC.
# =========================================
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.cluster_name}-vpc-endpoints-sg"
  description = "Allow HTTPS from within VPC to interface endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc-endpoints-sg"
  })
}

# =========================================
# GATEWAY ENDPOINTS — FREE, no hourly cost,
# no data processing charge, no SG needed.
# Traffic to these services never touches NAT.
# =========================================

# S3 Gateway Endpoint
# ECR stores image layers in S3. This single endpoint eliminates
# the largest source of NAT data charges on an EKS cluster.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.public.id
  ]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-s3-endpoint"
  })
}

# DynamoDB Gateway Endpoint
# Free, and some AWS services (e.g. certain SDK internals) use DynamoDB.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.public.id
  ]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-dynamodb-endpoint"
  })
}

# =========================================
# INTERFACE ENDPOINTS — ~$7-8/month each
# but save NAT data charges for high-volume
# AWS API traffic from nodes and pods.
# All placed in private subnets, private DNS enabled.
# =========================================

# ECR API — authentication and image manifest fetches
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ecr-api-endpoint"
  })
}

# ECR DKR — actual image layer pulls (docker registry protocol)
# Works together with the S3 endpoint: manifest via ecr.dkr,
# layers pulled from S3 — both bypass NAT entirely.
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ecr-dkr-endpoint"
  })
}

# EC2 — Karpenter makes heavy EC2 API calls:
# RunInstances, DescribeInstances, CreateFleet, TerminateInstances, etc.
resource "aws_vpc_endpoint" "ec2" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ec2-endpoint"
  })
}

# STS — IRSA token exchange.
# Karpenter controller, ALB controller, and EBS CSI driver all call
# sts:AssumeRoleWithWebIdentity on every pod startup and token refresh.
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-sts-endpoint"
  })
}

# SQS — Karpenter polls the interruption queue continuously.
# Without this endpoint every poll goes through NAT.
resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-sqs-endpoint"
  })
}

# EKS — node bootstrap calls and ongoing API server communication
# from the kubelet on each node use this endpoint.
resource "aws_vpc_endpoint" "eks" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.eks"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eks-endpoint"
  })
}

# SSM — required for SSM Session Manager (node shell access).
# Three endpoints are needed together: ssm, ssmmessages, ec2messages.
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ssm-endpoint"
  })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ssmmessages-endpoint"
  })
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ec2messages-endpoint"
  })
}