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

variable "external_domain_name" {
  type        = string
  description = "CloudFrontの接続先ドメイン名"
}

variable "subdomain_name" {
  type        = string
  description = "CloudFrontに割り当てるサブドメイン"
}
