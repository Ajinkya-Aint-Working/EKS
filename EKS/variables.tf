variable "region" {
  default = "ap-south-1"
}

variable "cluster_name" {
  default = "demo-eks"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "public_subnets" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "azs" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"]
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
      version = null
    },
    {
      name    = "coredns"
      version = null
    },
    {
      name    = "kube-proxy"
      version = null
    }
  ]
}