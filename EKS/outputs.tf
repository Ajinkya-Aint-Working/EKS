# =========================================
# EKS CLUSTER INFO
# =========================================
output "cluster_name" {
  value = aws_eks_cluster.eks.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.eks.endpoint
}

output "cluster_version" {
  value = aws_eks_cluster.eks.version
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

# =========================================
# KUBECTL CONFIG (IMPORTANT)
# =========================================
output "kubectl_config" {
  value = {
    cluster_name = aws_eks_cluster.eks.name
    region       = var.region
  }
}

# =========================================
# NODE GROUP INFO
# =========================================
output "node_group_name" {
  value = aws_eks_node_group.ondemand-node.node_group_name
}

output "node_group_status" {
  value = aws_eks_node_group.ondemand-node.status
}

# =========================================
# NETWORKING
# =========================================
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnets" {
  value = aws_subnet.public[*].id
}

output "internet_gateway_id" {
  value = aws_internet_gateway.igw.id
}

# =========================================
# SECURITY GROUPS
# =========================================
output "eks_cluster_sg" {
  value = aws_security_group.eks_cluster.id
}

output "node_sg" {
  value = aws_security_group.node.id
}

# =========================================
# IAM ROLES
# =========================================
output "eks_cluster_role_arn" {
  value = aws_iam_role.eks_cluster.arn
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}