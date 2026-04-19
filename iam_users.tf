locals {
  iam_users = {
    Knu334 = {
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    }
  }
}

resource "aws_iam_user" "users" {
  for_each = local.iam_users
  name     = each.key
}

resource "aws_iam_user_policy_attachment" "users" {
  for_each = {
    for item in flatten([
      for user, cfg in local.iam_users : [
        for arn in cfg.policy_arns : {
          key  = "${user}-${arn}"
          user = user
          arn  = arn
        }
      ]
    ]) : item.key => item
  }

  user       = aws_iam_user.users[each.value.user].name
  policy_arn = each.value.arn
}
