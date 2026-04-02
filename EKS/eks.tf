resource "aws_eks_cluster" "eks" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = aws_subnet.public[*].id
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

# =========================
# OIDC Provider
# =========================
data "tls_certificate" "eks" {
  url = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.eks.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# =========================
# Launch Template
# =========================
resource "aws_launch_template" "node" {
  name_prefix   = "eks-node"
  instance_type = var.instance_type
}

# =========================
# Node Group (ON DEMAND)
# =========================
resource "aws_eks_node_group" "ondemand-node" {
  cluster_name    = aws_eks_cluster.eks.name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = var.desired_size
    max_size     = 3
    min_size     = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_policies
  ]
}

# =========================
# Addons
# =========================
resource "aws_eks_addon" "eks-addons" {
  for_each      = { for idx, addon in var.addons : idx => addon }
  cluster_name  = aws_eks_cluster.eks.name
  addon_name    = each.value.name
  addon_version = each.value.version

  depends_on = [
    aws_eks_node_group.ondemand-node
  ]
}