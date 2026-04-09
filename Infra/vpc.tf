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

    # Required for Karpenter discovery
    "karpenter.sh/discovery" = var.cluster_name
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

  # ← NO ingress blocks here at all
  # ← KEEP egress inline — egress-only rules don't have this conflict

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # This is critical — tells Terraform "don't manage ingress inline"
  lifecycle {
    ignore_changes = [ingress]
  }

  tags = merge(var.tags, {
    Name                                        = "${var.cluster_name}-eks-cluster-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# =========================================
# NODE SECURITY GROUP
# =========================================
resource "aws_security_group" "node" {
  name   = "${var.cluster_name}-node-sg"
  vpc_id = aws_vpc.main.id

  # ← NO ingress blocks here

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes = [ingress]
  }

  tags = merge(var.tags, {
    Name                                        = "${var.cluster_name}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "karpenter.sh/discovery"                    = var.cluster_name
  })
}

# =========================================
# ALL INGRESS RULES AS SEPARATE RESOURCES
# =========================================

# Cluster → Node (all traffic)
resource "aws_security_group_rule" "cluster_to_node" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.node.id
  source_security_group_id = aws_security_group.eks_cluster.id
  description              = "Cluster to node all traffic"
}

# Node → Cluster (all traffic)
resource "aws_security_group_rule" "node_to_cluster" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.node.id
  description              = "Node to cluster all traffic"
}

# Node → Node (self)
resource "aws_security_group_rule" "node_to_node" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.node.id
  self              = true
  description       = "Node to node all traffic"
}

# Cluster API access (kubectl)
resource "aws_security_group_rule" "cluster_api_access" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.eks_cluster.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow HTTPS kubectl / API"
}

# ALB → Node ports
resource "aws_security_group_rule" "alb_to_node" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  security_group_id = aws_security_group.node.id
  cidr_blocks       = [var.vpc_cidr]
  description       = "Allow ALB to reach node ports"
}