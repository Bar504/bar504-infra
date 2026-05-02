output "iam_user_passwords" {
  description = "Initial passwords — valid until first login (reset required)"
  value       = { for k, v in aws_iam_user_login_profile.users : k => v.password }
  sensitive   = true
}

output "route53_zone_id" {
  value = data.aws_route53_zone.main.zone_id
}

output "acm_certificate_arn_tokyo" {
  value = aws_acm_certificate.main.arn
}

output "acm_certificate_arn_cloudfront" {
  description = "Use this ARN when attaching to CloudFront distributions"
  value       = aws_acm_certificate.cloudfront.arn
}
