

# =========================
# Null resource for alb installation dependency
# =========================

resource "null_resource" "wait_for_alb" {
  depends_on = [helm_release.alb]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name} && kubectl wait --namespace kube-system --for=condition=available deployment/aws-load-balancer-controller --timeout=300s"
  }
}


# =========================
# Karpenter Namespace
# =========================

resource "kubernetes_namespace_v1" "karpenter" {
  metadata {
    name = var.karpenter_namespace
  }
  depends_on = [null_resource.wait_for_nodes]
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
  cleanup_on_fail  = true
  timeout          = 600

  set = [
    {
      name  = "settings.clusterName"
      value = aws_eks_cluster.eks.name
    },

    {
      name  = "settings.interruptionQueue"
      value = aws_sqs_queue.karpenter_interruption.name
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
    aws_iam_role_policy.karpenter_controller_policy,
    aws_eks_access_entry.karpenter_node,
    kubernetes_namespace_v1.karpenter,
    null_resource.wait_for_alb,
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
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600

  depends_on = [
    kubernetes_namespace_v1.karpenter,
    null_resource.wait_for_alb
  ]
}
