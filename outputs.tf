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

output "claude_proxy_fqdn" {
  description = "FQDN of the Claude reverse proxy A record (empty if not configured)"
  value       = length(aws_route53_record.claude_proxy) > 0 ? aws_route53_record.claude_proxy[0].fqdn : ""
}
