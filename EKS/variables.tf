variable "region" {
  default = "ap-south-1"
}

variable "cluster_name" {
  default = "demo-eks"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "cluster_version" {
  default = 1.33
}


variable "instance_type" {
  default = "t3.medium"
}

variable "desired_size" {
  default = 2
}

variable "addons" {
  default = [
    {
      name    = "vpc-cni"
      version = "v1.20.0-eksbuild.1"
    },
    {
      name    = "coredns"
      version = "v1.12.2-eksbuild.4"
    },
    {
      name    = "kube-proxy"
      version = "v1.33.0-eksbuild.2"
    },
    {
      name    = "aws-ebs-csi-driver"
      version = "v1.46.0-eksbuild.1"
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