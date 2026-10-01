terraform {
  backend "s3" {
    bucket         = "tech-challenge-terraform-state-630013977255"
    key            = "tech-challenge/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}
