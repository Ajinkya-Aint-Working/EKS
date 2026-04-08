# =========================
# Tag subnets for Karpenter discovery
# =========================
resource "aws_ec2_tag" "karpenter_subnet_tags" {
  count       = var.public_subnet_count
  resource_id = aws_subnet.public[count.index].id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# =========================
# Tag node security group for Karpenter discovery
# =========================
resource "aws_ec2_tag" "karpenter_node_sg_tag" {
  resource_id = aws_security_group.node.id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# =========================
# EKS Access Entry for Karpenter Node Role
# (your cluster uses authentication_mode = "API", so no aws-auth ConfigMap needed)
# =========================
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

  depends_on = [aws_eks_cluster.eks]
}

# =========================
# Karpenter Helm Release
# =========================
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = var.karpenter_namespace
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  create_namespace = false
  wait             = true

  set = [
    {
    name  = "settings.clusterName"
    value = aws_eks_cluster.eks.name
    },

    {
    name  = "settings.interruptionQueue"
    value = aws_eks_cluster.eks.name
    },

    {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
    },

    {
    name  = "controller.resources.requests.cpu"
    value = "1"
    },

    {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
    },

    {
    name  = "controller.resources.limits.cpu"
    value = "1"
    },

    {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
    },

  # Pin Karpenter pods to the existing managed node group
    {
    name  = "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key"
    value = "eks.amazonaws.com/nodegroup"
    },

    {
    name  = "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator"
    value = "In"
    },
 
    {
    name  = "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]"
    value = aws_eks_node_group.ondemand-node.node_group_name
    }
  ]

  depends_on = [
    aws_eks_node_group.ondemand-node,
    aws_iam_role_policy.karpenter_controller_policy,
    aws_eks_access_entry.karpenter_node,
    aws_ec2_tag.karpenter_subnet_tags,
    aws_ec2_tag.karpenter_node_sg_tag,
    helm_release.karpenter_crds
  ]
}

# =========================
# Karpenter CRDs (installed separately for lifecycle safety)
# =========================
resource "helm_release" "karpenter_crds" {
  name             = "karpenter-crd"
  namespace        = var.karpenter_namespace
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = var.karpenter_version
  create_namespace = false

  depends_on = [aws_eks_node_group.ondemand-node]
}
