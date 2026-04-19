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

# ---------------------------------------------------------------------------
# Admin role — assume this when administrative operations are needed
# ---------------------------------------------------------------------------
resource "aws_iam_role" "admin" {
  name = "bar504-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_user.users["shokun"].arn }
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

# Allow shokun to assume the admin role
resource "aws_iam_user_policy" "shokun_assume_admin" {
  name = "assume-admin-role"
  user = aws_iam_user.users["shokun"].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.admin.arn
    }]
  })
}
