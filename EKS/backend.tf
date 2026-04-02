terraform {
  backend "s3" {
    bucket       = "terraform-state-bucket-951907775476-ap-south-1-an"
    key          = "terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}