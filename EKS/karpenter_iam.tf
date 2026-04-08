# =========================
# Karpenter Node IAM Role
# =========================
resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore"
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

# =========================
# Karpenter Controller IAM Role (IRSA)
# =========================
resource "aws_iam_role" "karpenter_controller" {
  name = "KarpenterControllerRole-${var.cluster_name}"

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
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com",
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:karpenter"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "karpenter_controller_policy" {
  name = "KarpenterControllerPolicy-${var.cluster_name}"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "Karpenter",
        Effect = "Allow",
        Action = [
          "ssm:GetParameter",
          "ec2:DescribeImages",
          "ec2:RunInstances",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateTags",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts"
        ],
        Resource = "*"
      },
      {
        Sid    = "ConditionalEC2Termination",
        Effect = "Allow",
        Action = "ec2:TerminateInstances",
        Resource = "*",
        Condition = {
          StringLike = {
            "ec2:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "PassNodeIAMRole",
        Effect   = "Allow",
        Action   = "iam:PassRole",
        Resource = aws_iam_role.karpenter_node.arn
      },
      {
        Sid      = "EKSClusterEndpointLookup",
        Effect   = "Allow",
        Action   = "eks:DescribeCluster",
        Resource = aws_eks_cluster.eks.arn
      },
      {
        Sid    = "AllowScopedInstanceProfileCreationActions",
        Effect = "Allow",
        Action = ["iam:CreateInstanceProfile"],
        Resource = "*",
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned",
            "aws:RequestTag/topology.kubernetes.io/region"             = var.region
          },
          StringLike = {
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileTagActions",
        Effect = "Allow",
        Action = ["iam:TagInstanceProfile"],
        Resource = "*",
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned",
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region,
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"  = "owned",
            "aws:RequestTag/topology.kubernetes.io/region"              = var.region
          },
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*",
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"  = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileActions",
        Effect = "Allow",
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile"
        ],
        Resource = "*",
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned",
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
          },
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowInstanceProfileReadActions",
        Effect   = "Allow",
        Action   = "iam:GetInstanceProfile",
        Resource = "*"
      },
      {
        Sid      = "AllowUnscopedInstanceProfileListAction",
        Effect   = "Allow",
        Action   = "iam:ListInstanceProfiles",
        Resource = "*"
      }
    ]
  })
}
