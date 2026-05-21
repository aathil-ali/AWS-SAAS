# -----------------------------------------------------------------------------
# IAM Identity Center (SSO) Permission Sets
# -----------------------------------------------------------------------------

# Fetch the Identity Center instance (must be manually enabled in AWS console first)
data "aws_ssoadmin_instances" "this" {}

# 1. Admin Permission Set (Full access everywhere)
resource "aws_ssoadmin_permission_set" "admin" {
  name             = "Admin"
  description      = "Full administrative access"
  instance_arn     = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  session_duration = "PT8H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin_access" {
  instance_arn       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
}

# 2. Developer Permission Set
resource "aws_ssoadmin_permission_set" "developer" {
  name             = "Developer"
  description      = "Developer access"
  instance_arn     = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  session_duration = "PT8H"
}

resource "aws_ssoadmin_managed_policy_attachment" "developer_access" {
  instance_arn       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  # Note: A single permission set applies the exact same policy in all assigned accounts.
  # For the architecture's requirement of "Staging: Admin, Prod: Read-only", 
  # we either need two separate permission sets (e.g., DeveloperStaging, DeveloperProd) 
  # or we use Permission Boundaries. For simplicity here, we're giving PowerUserAccess.
  managed_policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
  permission_set_arn = aws_ssoadmin_permission_set.developer.arn
}

# 3. DevOps Permission Set
resource "aws_ssoadmin_permission_set" "devops" {
  name             = "DevOps"
  description      = "DevOps and deployment access"
  instance_arn     = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  session_duration = "PT8H"
}

resource "aws_ssoadmin_managed_policy_attachment" "devops_access" {
  instance_arn       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  permission_set_arn = aws_ssoadmin_permission_set.devops.arn
}

# -----------------------------------------------------------------------------
# Assignments (Requires User/Group IDs from Identity Store)
# -----------------------------------------------------------------------------
# You would map the groups from your Identity Store to these permission sets here.
# Example:
# resource "aws_ssoadmin_account_assignment" "admin_staging" {
#   instance_arn       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
#   target_id          = aws_organizations_account.staging.id
#   target_type        = "AWS_ACCOUNT"
#   permission_set_arn = aws_ssoadmin_permission_set.admin.arn
#   principal_id       = "GROUP_ID_FROM_IDENTITY_STORE"
#   principal_type     = "GROUP"
# }
