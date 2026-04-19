locals {
  iam_groups = {
    readonly = {
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    }
  }

  iam_users = {
    Knu334 = {
      groups = ["readonly"]
    }
    shokun = {
      groups = ["readonly"]
    }
  }
}

resource "aws_iam_group" "groups" {
  for_each = local.iam_groups
  name     = each.key
}

resource "aws_iam_group_policy_attachment" "groups" {
  for_each = {
    for item in flatten([
      for group, cfg in local.iam_groups : [
        for arn in cfg.policy_arns : {
          key   = "${group}-${arn}"
          group = group
          arn   = arn
        }
      ]
    ]) : item.key => item
  }

  group      = aws_iam_group.groups[each.value.group].name
  policy_arn = each.value.arn
}

resource "aws_iam_user" "users" {
  for_each = local.iam_users
  name     = each.key
}

resource "aws_iam_user_group_membership" "users" {
  for_each = local.iam_users
  user     = aws_iam_user.users[each.key].name
  groups   = [for g in each.value.groups : aws_iam_group.groups[g].name]
}

resource "aws_iam_user_login_profile" "users" {
  for_each                = local.iam_users
  user                    = aws_iam_user.users[each.key].name
  password_reset_required = true
}

# ---------------------------------------------------------------------------
# Admin role — assume this when administrative operations are needed
# ---------------------------------------------------------------------------
resource "aws_iam_role" "admin" {
  name = "bar504-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        BoolIfExists = {
          "aws:MultiFactorAuthPresent" = "true"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Allow all readonly group members to assume the admin role
resource "aws_iam_group_policy" "readonly_assume_admin" {
  name  = "assume-admin-role"
  group = aws_iam_group.groups["readonly"].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.admin.arn
    }]
  })
}

# Allow users to manage their own password and MFA
resource "aws_iam_group_policy" "readonly_self_service" {
  name  = "self-service-iam"
  group = aws_iam_group.groups["readonly"].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:ChangePassword",
          "iam:GetUser",
          "iam:GetAccountPasswordPolicy",
          "iam:GetAccountSummary",
          "iam:ListMFADevices",
          "iam:ListVirtualMFADevices",
          "iam:CreateVirtualMFADevice",
          "iam:DeleteVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:DeactivateMFADevice",
          "iam:ResyncMFADevice",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:ListAccessKeys",
          "iam:UpdateAccessKey",
        ]
        Resource = [
          "arn:aws:iam::*:user/$${aws:username}",
          "arn:aws:iam::*:mfa/$${aws:username}",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "iam:GetAccountPasswordPolicy"
        Resource = "*"
      },
    ]
  })
}

data "aws_caller_identity" "current" {}
