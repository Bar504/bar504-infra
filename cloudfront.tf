# ---------------------------------------------------------
# 事前共有キーの生成
# ---------------------------------------------------------
resource "random_password" "cf_shared_secret" {
  length  = 32
  special = false
}

# ---------------------------------------------------------
# AWS管理ポリシーのデータソース取得
# ---------------------------------------------------------
# キャッシュ有効（デフォルト用）
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# キャッシュ無効
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# 全てのヘッダー/Cookie/クエリをオリジンに渡す
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# ---------------------------------------------------------
# 既存リソースの取得 (データソース)
# ---------------------------------------------------------
# 1. 既存のRoute 53ホストゾーンを取得
data "aws_route53_zone" "main" {
  name = var.domain_name
}

# 2. us-east-1にあるACM証明書を取得
data "aws_acm_certificate" "cf_cert" {
  domain      = var.domain_name
  types       = ["AMAZON_ISSUED"]
  most_recent = true
}

# ---------------------------------------------------------
# CloudFront ディストリビューション
# ---------------------------------------------------------
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [var.subdomain_name]

  # オリジンの設定
  origin {
    domain_name = var.external_domain_name
    origin_id   = "ExternalVPSOrigin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2", "TLSv1.3"]
    }

    # 事前共有キーをカスタムヘッダーとして付与
    custom_header {
      name  = "X-Shared-Secret"
      value = random_password.cf_shared_secret.result
    }
  }

  # デフォルトのキャッシュビヘイビア (静的アセットなどを想定)
  default_cache_behavior {
    target_origin_id       = "ExternalVPSOrigin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  # OAuth認証用パスのキャッシュ無効化設定
  ordered_cache_behavior {
    path_pattern           = "/auth/*"
    target_origin_id       = "ExternalVPSOrigin"
    viewer_protocol_policy = "redirect-to-https"
    
    # OAuthやAPIのPOST等を通すために全てのメソッドを許可
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    # キャッシュを無効にし、クライアントのリクエスト内容をそのままオリジンへ渡す
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # API用パスのキャッシュ無効化設定
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "ExternalVPSOrigin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # Geo Restriction (日本以外からのアクセスを拒否)
  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["JP"]
    }
  }

  # 証明書設定 (デフォルトのCloudFront証明書を使用)
  viewer_certificate {
 acm_certificate_arn      = data.aws_acm_certificate.cf_cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ---------------------------------------------------------
# Route 53 DNSレコードの作成
# ---------------------------------------------------------
resource "aws_route53_record" "cf_record" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.subdomain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}