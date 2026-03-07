terraform {
  backend "s3" {
    bucket  = "datavisyn-devops-challenge-terraform-backend"
    key     = "global/terraform.tfstate"
    region  = "eu-central-1"
    encrypt = true
  }
}
