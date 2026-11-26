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

output "homehub_backup_bucket" {
  value = aws_s3_bucket.homehub_backup.bucket
}

output "keiba_site_url" {
  description = "友人向け競馬予想サイトの URL（S3 静的ウェブサイト・HTTP）"
  value       = "http://${aws_s3_bucket_website_configuration.keiba_site.website_endpoint}"
}
