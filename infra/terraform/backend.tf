terraform {
  backend "s3" {
    bucket         = "vaultops-tfstate-269531437067"
    key            = "vaultops/terraform.tfstate"
    region         = "ap-south-1"
    use_lockfile   = true
    encrypt        = true
  }
}
