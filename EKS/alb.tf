# IAM Policy for ALB
resource "aws_iam_policy" "alb" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/policies/alb_iam_policy.json")
}

# IAM Role for Service Account
resource "aws_iam_role" "alb" {
  name = "alb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_attach" {
  role       = aws_iam_role.alb.name
  policy_arn = aws_iam_policy.alb.arn
}

resource "null_resource" "wait_for_nodes" {
  depends_on = [
    aws_eks_cluster.eks,
    aws_eks_node_group.ondemand-node
  ]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name} && kubectl wait --for=condition=Ready nodes --all --timeout=300s"
  }
}

# Kubernetes Service Account
resource "kubernetes_service_account_v1" "alb" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb.arn
    }
  }

  depends_on = [null_resource.wait_for_nodes]
}

# Helm Install
resource "helm_release" "alb" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  # cleanup_on_fail ensures that if the Helm release installation fails, it will be automatically cleaned up, preventing orphaned resources and ensuring a clean state for subsequent attempts.
  cleanup_on_fail = true
  wait            = true
  timeout         = 600


  depends_on = [
    null_resource.wait_for_nodes
  ]

  set = [
    {
      name  = "clusterName"
      value = var.cluster_name
    },
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account_v1.alb.metadata[0].name
    },
    {
      name  = "vpcId"
      value = aws_vpc.main.id
    }
  ]
}