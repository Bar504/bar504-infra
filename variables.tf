variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "domain_name" {
  type        = string
  description = "The root domain name (e.g. bar504.com)"
}

variable "github_org" {
  type        = string
  description = "GitHub organization or user name (e.g. Bar504)"
  default     = "Bar504"
}

variable "knu334_domain_name" {
  type        = string
  description = "Knu334ドメイン名"
}

variable "tsu_chiman2_domain_name" {
  type        = string
  description = "tsu-chiman2用サブドメイン"
}

variable "discord_webhook_url" {
  type        = string
  description = "Discord webhook URL for CloudWatch alarm notifications"
  sensitive   = true
}

variable "cloudfront_distribution_ids" {
  type        = map(string)
  description = "CloudFront distribution IDs keyed by name (e.g. { taskmanager = \"EXXX\" })"
  default     = {}
}

variable "cloudfront_request_threshold" {
  type        = number
  description = "CloudFront requests per 5 minutes that triggers an alarm"
  default     = 300
}

variable "cloudfront_bandwidth_threshold_bytes" {
  type        = number
  description = "CloudFront bytes downloaded per 5 minutes that triggers an alarm (default 500 MB)"
  default     = 524288000
}

variable "route53_dns_query_threshold" {
  type        = number
  description = "Route 53 DNS queries per 5 minutes that triggers an alarm"
  default     = 500
}

variable "acm_cert_expiry_days" {
  type        = number
  description = "Days before ACM certificate expiry to trigger an alarm"
  default     = 30
}

variable "billing_alarm_threshold_usd" {
  type        = number
  description = "Monthly estimated charges (USD) that triggers an alarm"
  default     = 10
}
