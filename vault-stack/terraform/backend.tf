terraform {
  backend "s3" {
    bucket       = "vault-infra-tfstate-<account-id>" # Replace with actual account ID after bootstrap
    key          = "vault/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    kms_key_id   = "alias/terraform-state"
    use_lockfile = true # S3 native locking (Terraform 1.10+), no DynamoDB needed
  }
}
