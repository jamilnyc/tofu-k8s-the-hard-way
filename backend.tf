# Backend blocks can't reference variables -- these values have to be
# hardcoded. Replace bucket/dynamodb_table/profile below with your own
# pre-existing S3 bucket, DynamoDB lock table, and AWS CLI profile before
# running `tofu init` (see README.md).
terraform {
  backend "s3" {
    bucket         = "CHANGEME-terraform-state-bucket"
    key            = "k8s-hard-way.tfstate"
    region         = "us-east-1"
    dynamodb_table = "CHANGEME-terraform-state-lock"
    encrypt        = true
    profile        = "CHANGEME-aws-profile"
  }
}
