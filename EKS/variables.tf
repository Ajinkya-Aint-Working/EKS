variable "region" {
  default = "ap-south-1"
}

variable "cluster_name" {
  default = "demo"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "cluster_version" {
  default = 1.35
}


variable "instance_type" {
  default = "t3.medium"
}

variable "desired_size" {
  default = 2
}

variable "max_size" {
  default = 3
}

variable "min_size" {
  default = 1
}

variable "addons" {
  default = [
    {
      name    = "vpc-cni"
      version = "v1.21.1-eksbuild.1"
    },
    {
      name    = "coredns"
      version = "v1.13.2-eksbuild.3"
    },
    {
      name    = "kube-proxy"
      version = "v1.35.0-eksbuild.2"
    },
    {
      name    = "aws-ebs-csi-driver"
      version = "v1.57.1-eksbuild.1"
    }
  ]
}

variable "public_subnet_count" {
  default = 2
}

variable "tags" {
  type = map(string)
  default = {
    Environment = "dev"
    Terraform   = "true"
  }
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  default     = "1.11.0"
}
