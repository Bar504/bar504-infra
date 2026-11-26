# ---------------------------------------------------------------------------
# 競馬予想の静的サイト（友人向け・S3 静的ウェブサイトホスティング）
#   homehub の cron（金夜・土夜）が週末の重賞の予想 JSON と HTML を aws s3 sync で送る。
#   中身は予想の確率と買い方だけで個人情報なし。URL がバケット名から決まるので、名前に乱数を入れて推測されにくくしている。
#   HTTP のみ（CloudFront は使わない構成をユーザーが選択）。
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

# ACL での公開は禁止し、下のバケットポリシー（GetObject のみ）でだけ公開する
resource "aws_s3_bucket_public_access_block" "keiba_site" {
  bucket                  = aws_s3_bucket.keiba_site.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "keiba_site" {
  bucket = aws_s3_bucket.keiba_site.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_policy" "keiba_site" {
  bucket     = aws_s3_bucket.keiba_site.id
  depends_on = [aws_s3_bucket_public_access_block.keiba_site]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.keiba_site.arn}/*"
    }]
  })
}

# 古いレースの JSON がたまり続けないよう 180 日で消す（一覧に出るのは直近2週間だけ）
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
