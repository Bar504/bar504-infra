locals {
  iam_groups = {
    readonly = {
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    }
    admin = {
      policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    }
  }

  iam_users = {
    Knu334 = {
      groups = ["readonly"]
    }
    shokun = {
      groups = ["admin"]
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
