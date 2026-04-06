# =========================================
# VPC
# =========================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc"
  })
}

# =========================================
# INTERNET GATEWAY
# =========================================
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-igw"
  })
}

# =========================================
# AVAILABILITY ZONES
# =========================================
data "aws_availability_zones" "available" {}

# =========================================
# PUBLIC SUBNETS (DYNAMIC CIDR)
# =========================================
resource "aws_subnet" "public" {
  count = var.public_subnet_count

  vpc_id = aws_vpc.main.id

  # Split VPC CIDR into smaller /24 blocks
  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index)

  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-public-${count.index}"

    # Required for ALB Controller
    "kubernetes.io/role/elb" = "1"

    # Required for EKS
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# =========================================
# ROUTE TABLE
# =========================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-public-rt"
  })
}

# =========================================
# INTERNET ROUTE
# =========================================
resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# =========================================
# ROUTE TABLE ASSOCIATION
# =========================================
resource "aws_route_table_association" "public_assoc" {
  count = var.public_subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# =========================================
# EKS CLUSTER SECURITY GROUP
# =========================================
resource "aws_security_group" "eks_cluster" {
  name   = "${var.cluster_name}-eks-cluster-sg"
  vpc_id = aws_vpc.main.id

  # API access (kubectl)
  ingress {
    description = "Allow HTTPS (kubectl / API)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"

    # ⚠️ Restrict this in production
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eks-cluster-sg"
    # Tells EKS this SG belongs to the cluster
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# =========================================
# NODE SECURITY GROUP
# =========================================
resource "aws_security_group" "node" {
  name   = "${var.cluster_name}-node-sg"
  vpc_id = aws_vpc.main.id

  # Node-to-node communication
  ingress {
    description = "Allow node to node"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-node-sg"
    # Required — ALB controller uses this to find node SGs
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# =========================================
# SECURITY GROUP RULES (NO CIRCULAR DEPENDENCY)
# =========================================

# Cluster → Node communication
resource "aws_security_group_rule" "cluster_to_node" {
  type      = "ingress"
  from_port = 0
  to_port   = 0
  protocol  = "-1"

  security_group_id        = aws_security_group.node.id
  source_security_group_id = aws_security_group.eks_cluster.id
}

# Node → Cluster communication
resource "aws_security_group_rule" "node_to_cluster" {
  type      = "ingress"
  from_port = 0
  to_port   = 0
  protocol  = "-1"

  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.node.id
}

# ALB → Node ports (required for ALB target group health checks)
resource "aws_security_group_rule" "alb_to_node" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  security_group_id = aws_security_group.node.id
  cidr_blocks       = [var.vpc_cidr] # scope to VPC, not 0.0.0.0/0
  description       = "Allow ALB to reach node ports"
}