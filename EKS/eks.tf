resource "aws_eks_cluster" "eks" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

# =========================
# OIDC Provider
# =========================
data "tls_certificate" "eks" {
  url        = aws_eks_cluster.eks.identity[0].oidc[0].issuer
  depends_on = [aws_eks_cluster.eks]
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

  vpc_security_group_ids = [aws_security_group.node.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }
}

# =========================
# Node Group (ON DEMAND)
# =========================
resource "aws_eks_node_group" "ondemand-node" {
  cluster_name  = aws_eks_cluster.eks.name
  node_role_arn = aws_iam_role.node.arn
  subnet_ids    = aws_subnet.public[*].id
  capacity_type = "ON_DEMAND"

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = "$Latest"
  }

  labels = {
    "type" = "ondemand"
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