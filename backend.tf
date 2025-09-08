terraform {
  backend "s3" {
    bucket         = "terraformstatefile090909"
    key            = "module_eks_karpenter_dev_terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
