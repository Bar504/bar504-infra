# ---------------------------------------------------------------------------
# 競馬予想の静的サイト（友人向け・S3 ＋ CloudFront）
#   homehub の cron（金夜、土日の朝・昼・夜）が週末の重賞の予想 JSON と HTML を aws s3 sync で送る。
#   中身は予想の確率と買い方だけで個人情報なし。
#   2026-11-26: netkeiba 利用規約（第14条: 不特定多数が知りうる状態に置かない）に合わせ、
#   CloudFront ＋ Basic 認証の友人限定に変更。S3 は非公開にして CloudFront（OAC）からだけ読む。
#   認証情報はコードにも state にも置かず、CloudFront KeyValueStore にキー "basic" として CLI で入れる
#   （keiba リポジトリの scripts/set-site-password.sh）。未設定のあいだは全員 401。
#   2026-11-28: 毎回のログインが面倒なので、Basic 認証が通ったら 30 日有効のクッキー（keiba_auth）を発行し、
#   以後はクッキーだけで通す。クッキーの値は認証情報の SHA-256 なので、パスワードを変えると全員分が無効になる。
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "keiba_site" {
  bucket = "bar504-uma-3fsl1m"
}

resource "aws_s3_bucket_ownership_controls" "keiba_site" {
  bucket = aws_s3_bucket.keiba_site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# 公開はしない（CloudFront の OAC 経由だけ）
resource "aws_s3_bucket_public_access_block" "keiba_site" {
  bucket                  = aws_s3_bucket.keiba_site.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "keiba_site" {
  bucket     = aws_s3_bucket.keiba_site.id
  depends_on = [aws_s3_bucket_public_access_block.keiba_site]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudFrontOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.keiba_site.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.keiba_site.arn }
      }
    }]
  })
}

# 古いレースの JSON がたまり続けないよう 180 日で消す（一覧に出るのは直近1ヶ月だけ）
resource "aws_s3_bucket_lifecycle_configuration" "keiba_site" {
  bucket = aws_s3_bucket.keiba_site.id

  rule {
    id     = "expire-old-race-data"
    status = "Enabled"
    filter {
      prefix = "data/races/"
    }
    expiration {
      days = 180
    }
  }

  rule {
    id     = "cleanup"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ---------------------------------------------------------------------------
# homehub 用のアップロード専用ユーザー
#   このバケットへの List/Put/Delete だけ。アクセスキーは state に秘密を残さないよう CLI で発行する。
# ---------------------------------------------------------------------------
resource "aws_iam_user" "keiba_site_publisher" {
  name = "keiba-site-publisher"
}

resource "aws_iam_user_policy" "keiba_site_publisher" {
  name = "keiba-site-publish"
  user = aws_iam_user.keiba_site_publisher.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.keiba_site.arn
      },
      {
        Sid      = "WriteObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.keiba_site.arn}/*"
      },
      {
        # 同名バケットを他アカウントに取られても（消した後の再取得など）そこへは送らない
        Sid      = "DenyOtherAccountsBuckets"
        Effect   = "Deny"
        Action   = "s3:*"
        Resource = "*"
        Condition = {
          StringNotEquals = { "s3:ResourceAccount" = "$${aws:PrincipalAccount}" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudFront ＋ Basic 認証
# ---------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "keiba_site" {
  name                              = "keiba-site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 認証情報の置き場所。値（キー "basic" = "Basic <base64(ユーザー:パスワード)>"）は Terraform では入れない
resource "aws_cloudfront_key_value_store" "keiba_site_auth" {
  name    = "keiba-site-auth"
  comment = "Basic auth credential for keiba site (set via CLI, not in Terraform)"
}

resource "aws_cloudfront_function" "keiba_site_auth" {
  name                         = "keiba-site-basic-auth"
  runtime                      = "cloudfront-js-2.0"
  comment                      = "Basic auth for keiba site (credential in KeyValueStore)"
  publish                      = true
  key_value_store_associations = [aws_cloudfront_key_value_store.keiba_site_auth.arn]
  code                         = <<-EOT
    import cf from 'cloudfront';
    import crypto from 'crypto';
    const kvs = cf.kvs();

    // ログインを覚えるクッキー。値は認証情報から作るので、パスワードを変えると全員分が無効になる
    function token(want) {
      return crypto.createHash('sha256').update('keiba-remember:' + want).digest('hex');
    }

    function deny() {
      return {
        statusCode: 401,
        statusDescription: 'Unauthorized',
        headers: { 'www-authenticate': { value: 'Basic realm="keiba", charset="UTF-8"' } }
      };
    }

    async function handler(event) {
      const req = event.request;
      const got = req.headers.authorization ? req.headers.authorization.value : '';
      const ck = req.cookies.keiba_auth ? req.cookies.keiba_auth.value : '';
      let want = '';
      try {
        want = await kvs.get('basic');
      } catch (e) {
        return deny();   // 未設定なら誰も通さない
      }
      if (!want || (got !== want && ck !== token(want))) {
        return deny();
      }
      return req;
    }
  EOT
}

# Basic 認証が通ったレスポンスに、ログインを 30 日覚えるクッキーを付ける（すでに有効なクッキーがあれば付けない）
resource "aws_cloudfront_function" "keiba_site_remember" {
  name                         = "keiba-site-remember-login"
  runtime                      = "cloudfront-js-2.0"
  comment                      = "Set remember-login cookie after basic auth (keiba site)"
  publish                      = true
  key_value_store_associations = [aws_cloudfront_key_value_store.keiba_site_auth.arn]
  code                         = <<-EOT
    import cf from 'cloudfront';
    import crypto from 'crypto';
    const kvs = cf.kvs();

    function token(want) {
      return crypto.createHash('sha256').update('keiba-remember:' + want).digest('hex');
    }

    async function handler(event) {
      const req = event.request;
      const res = event.response;
      const got = req.headers.authorization ? req.headers.authorization.value : '';
      const ck = req.cookies.keiba_auth ? req.cookies.keiba_auth.value : '';
      let want = '';
      try {
        want = await kvs.get('basic');
      } catch (e) {
        return res;
      }
      if (want && got === want && ck !== token(want)) {
        res.cookies.keiba_auth = {
          value: token(want),
          attributes: 'Max-Age=2592000; Path=/; Secure; HttpOnly; SameSite=Lax'
        };
      }
      return res;
    }
  EOT
}

resource "aws_cloudfront_distribution" "keiba_site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "keiba site (friends only, basic auth)"
  default_root_object = "index.html"
  price_class         = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.keiba_site.bucket_regional_domain_name
    origin_id                = "keiba-site-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.keiba_site.id
  }

  default_cache_behavior {
    target_origin_id       = "keiba-site-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    # オリジンの Cache-Control に従う（HTML/JS は5分、data/ は no-cache を publish.sh が付ける）
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress        = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.keiba_site_auth.arn
    }

    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.keiba_site_remember.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
