# ---------------------------------------------------------
# 事前共有キーの生成
# ---------------------------------------------------------
resource "random_password" "tsu_chiman2_shared_secret" {
  length  = 32
  special = false

  keepers = {
    rotation_id = "v1" 
  }
}

# 事前共有キーをSSMパラメータストアに保存
resource "aws_ssm_parameter" "tsu_chiman2_shared_secret" {
  name  = "/tsu-chiman2/shared-secret"
  type  = "SecureString"
  value = random_password.tsu_chiman2_shared_secret.result
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
resource "aws_cloudfront_origin_request_policy" "tsu_chiman2_policy" {
  name    = "Custom-AllViewer-With-Viewer-Address"
  comment = "Pass all headers/cookies/queries and include CloudFront-Viewer-Address"

  cookies_config {
    cookie_behavior = "all"
  }
  query_strings_config {
    query_string_behavior = "all"
  }
  headers_config {
    header_behavior = "whitelist"
    headers {
      items = [
        # --- セキュリティ・通信 ---
        "Origin",
        "Authorization",
        "Accept",
        "Accept-Language",
        "Content-Type",

        # --- ユーザー属性・分析 ---
        "User-Agent",
        "Referer",

        # --- CORSプリフライト関連 ---
        "Access-Control-Request-Method",
        "Access-Control-Request-Headers",

        # --- CloudFront特有 ---
        "CloudFront-Viewer-Address",
        "CloudFront-Viewer-Country",
      ]
    }
  }
}

# 静的アセット用
resource "aws_cloudfront_origin_request_policy" "tsu_chiman2_assets_policy" {
  name    = "Custom-Assets-ViewerAddress-Only"
  comment = "For /assets/*: no cookies, no query strings, forward CloudFront-Viewer-Address"

  cookies_config {
    cookie_behavior = "none"
  }
  query_strings_config {
    query_string_behavior = "none"
  }
  headers_config {
    header_behavior = "allViewerAndWhitelistCloudFront"
    headers {
      items = [
        "CloudFront-Viewer-Address",
        "CloudFront-Viewer-Country",
      ]
    }
  }
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
resource "aws_cloudfront_distribution" "tsu_chiman2" {
  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [var.tsu_chiman2_domain_name]

  # オリジンの設定
  origin {
    domain_name = var.knu334_domain_name
    origin_id   = "Knu334VPSOrigin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # 事前共有キーをカスタムヘッダーとして付与
    custom_header {
      name  = "Tsu-Chiman2-Shared-Secret"
      value = random_password.tsu_chiman2_shared_secret.result
    }
  }

  # デフォルトのキャッシュビヘイビア
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

  # ルートのキャッシュ無効化設定
  ordered_cache_behavior {
    path_pattern             = "/"
    target_origin_id         = "Knu334VPSOrigin"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.tsu_chiman2_policy.id
  }

  # ServiceWorkerのキャッシュ無効化設定
  ordered_cache_behavior {
    path_pattern             = "/sw.js"
    target_origin_id         = "Knu334VPSOrigin"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.tsu_chiman2_policy.id
  }

  # 静的アセット用パスのキャッシュ設定
  ordered_cache_behavior {
    path_pattern             = "/assets/*"
    target_origin_id         = "Knu334VPSOrigin"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.tsu_chiman2_assets_policy.id
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
    origin_request_policy_id = aws_cloudfront_origin_request_policy.tsu_chiman2_policy.id
  }

  # API用パスのキャッシュ無効化設定
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "Knu334VPSOrigin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.tsu_chiman2_policy.id
  }

  # Geo Restriction (日本以外からのアクセスを拒否)
  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["JP"]
    }
  }

  # 証明書設定
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cloudfront.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ---------------------------------------------------------
# Route 53 DNSレコードの作成
# ---------------------------------------------------------
resource "aws_route53_record" "tsu_chiman2" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.tsu_chiman2_domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.tsu_chiman2.domain_name
    zone_id                = aws_cloudfront_distribution.tsu_chiman2.hosted_zone_id
    evaluate_target_health = false
  }
}
