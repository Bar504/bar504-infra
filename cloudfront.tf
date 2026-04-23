# ---------------------------------------------------------
# 事前共有キーの生成
# ---------------------------------------------------------
resource "random_password" "cf_shared_secret" {
  length  = 32
  special = false

  keepers = {
    rotation_id = "v1" 
  }
}

# 事前共有キーをSSMパラメータストアに保存
resource "aws_ssm_parameter" "cf_shared_secret" {
  name  = "/tsu-chiman2/cf-shared-secret" # パラメータ名
  type  = "SecureString"            # 暗号化して保存
  value = random_password.cf_shared_secret.result
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

# ---------------------------------------------------------
# カスタムオリジンリクエストポリシーの作成
# ---------------------------------------------------------
resource "aws_cloudfront_origin_request_policy" "custom_policy" {
  name    = "Custom-AllViewer-With-Viewer-Address"
  comment = "Pass all headers/cookies/queries and include CloudFront-Viewer-Address"

  cookies_config {
    cookie_behavior = "all"
  }
  query_strings_config {
    query_string_behavior = "all"
  }
  headers_config {
    header_behavior = "allViewerAndWhitelistCloudFront"
    headers {
      items = [
        "CloudFront-Viewer-Address",
        "CloudFront-Viewer-Country", # 日本限定フィルタのデバッグ等にも便利です
      ]
    }
  }
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
# 指定パス以外のアクセスをブロックするCloudFront Function
# ---------------------------------------------------------
resource "aws_cloudfront_function" "block_all" {
  name    = "block-unauthorized-paths"
  runtime = "cloudfront-js-2.0"
  comment = "Block all requests by default"
  publish = true
  code    = <<-EOT
    function handler(event) {
        // 全てのリクエストに対して 403 Forbidden を即座に返す
        return {
            statusCode: 403,
            statusDescription: 'Forbidden',
            headers: {
                'content-type': { value: 'text/plain' }
            },
            body: 'Access Denied: This path is not allowed.'
        };
    }
  EOT
}

# ---------------------------------------------------------
# CloudFront ディストリビューション
# ---------------------------------------------------------
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [var.tsu-chiman2_domain_name]

  # オリジンの設定
  origin {
    domain_name = var.knu334_domain_name
    origin_id   = "Knu334VPSOrigin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2", "TLSv1.3"]
    }

    # 事前共有キーをカスタムヘッダーとして付与
    custom_header {
      name  = "Tsu-Chiman2-Shared-Secret"
      value = random_password.cf_shared_secret.result
    }
  }

  # デフォルトのキャッシュビヘイビア (静的アセットなどを想定)
  default_cache_behavior {
    target_origin_id       = "Knu334VPSOrigin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id

    # ブロック用Functionを関連付け
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.block_all.arn
    }
  }

  # OAuth認証用パスのキャッシュ無効化設定
  ordered_cache_behavior {
    path_pattern           = "/auth/*"
    target_origin_id       = "Knu334VPSOrigin"
    viewer_protocol_policy = "redirect-to-https"
    
    # OAuthやAPIのPOST等を通すために全てのメソッドを許可
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    # キャッシュを無効にし、クライアントのリクエスト内容をそのままオリジンへ渡す
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.custom_policy.id
  }

  # API用パスのキャッシュ無効化設定
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "Knu334VPSOrigin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.custom_policy.id
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
  name    = var.tsu-chiman2_domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}