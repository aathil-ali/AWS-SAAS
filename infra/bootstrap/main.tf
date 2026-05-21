terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Application = "aws-saas"
      Team        = "platform"
      CostCenter  = "engineering"
    }
  }
}

# -----------------------------------------------------------------------------
# AWS Organization & Accounts
# -----------------------------------------------------------------------------
resource "aws_organizations_organization" "org" {
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "sso.amazonaws.com",
    "guardduty.amazonaws.com",
    "securityhub.amazonaws.com"
  ]

  feature_set = "ALL"
}

resource "aws_organizations_account" "staging" {
  name  = "aws-saas-staging"
  email = "your-email+staging@example.com" # TODO: Replace with real email
  
  parent_id = aws_organizations_organization.org.roots[0].id
}

resource "aws_organizations_account" "production" {
  name  = "aws-saas-production"
  email = "your-email+production@example.com" # TODO: Replace with real email
  
  parent_id = aws_organizations_organization.org.roots[0].id
}

# -----------------------------------------------------------------------------
# State Bootstrapping - Staging Account
# -----------------------------------------------------------------------------
provider "aws" {
  alias  = "staging"
  region = "us-east-1"
  assume_role {
    role_arn = "arn:aws:iam::${aws_organizations_account.staging.id}:role/OrganizationAccountAccessRole"
  }
  default_tags {
    tags = {
      Environment = "staging"
      ManagedBy   = "terraform"
      Application = "aws-saas"
      Team        = "platform"
      CostCenter  = "engineering"
    }
  }
}

resource "aws_s3_bucket" "staging_state" {
  provider = aws.staging
  bucket   = "aws-saas-staging-tfstate"
}

resource "aws_s3_bucket_versioning" "staging_state_versioning" {
  provider = aws.staging
  bucket   = aws_s3_bucket.staging_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "staging_lock" {
  provider     = aws.staging
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# -----------------------------------------------------------------------------
# State Bootstrapping - Production Account
# -----------------------------------------------------------------------------
provider "aws" {
  alias  = "production"
  region = "us-east-1"
  assume_role {
    role_arn = "arn:aws:iam::${aws_organizations_account.production.id}:role/OrganizationAccountAccessRole"
  }
  default_tags {
    tags = {
      Environment = "production"
      ManagedBy   = "terraform"
      Application = "aws-saas"
      Team        = "platform"
      CostCenter  = "engineering"
    }
  }
}

resource "aws_s3_bucket" "production_state" {
  provider = aws.production
  bucket   = "aws-saas-production-tfstate"
}

resource "aws_s3_bucket_versioning" "production_state_versioning" {
  provider = aws.production
  bucket   = aws_s3_bucket.production_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "production_lock" {
  provider     = aws.production
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
