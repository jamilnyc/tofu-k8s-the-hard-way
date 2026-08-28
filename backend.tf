terraform {
  backend "s3" {
    bucket         = "jamil-personal-terraform-state"
    key            = "k8s-hard-way.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
    profile        = "terraform-personal"
  }
}
