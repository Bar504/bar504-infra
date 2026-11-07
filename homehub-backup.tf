# ---------------------------------------------------------------------------
# homehub（自宅サーバー）の写真バックアップ先
#   homehub から aws s3 sync --storage-class DEEP_ARCHIVE で週1回送る。
#   復元は bar504-admin ロールで行う（Deep Archive の取り出しは 12〜48 時間）。
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "homehub_backup" {
  bucket = "bar504-homehub-backup"

  # 唯一の遠隔コピーなので destroy では消えないようにする
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "homehub_backup" {
  bucket                  = aws_s3_bucket.homehub_backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "homehub_backup" {
  bucket = aws_s3_bucket.homehub_backup.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "homehub_backup" {
  bucket = aws_s3_bucket.homehub_backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-KMS はリクエスト課金が乗るので S3 管理鍵で十分
    }
  }
}

# 上書き・削除されても旧バージョンから戻せるようにする（ランサムウェア対策）
resource "aws_s3_bucket_versioning" "homehub_backup" {
  bucket = aws_s3_bucket.homehub_backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "homehub_backup" {
  bucket     = aws_s3_bucket.homehub_backup.id
  depends_on = [aws_s3_bucket_versioning.homehub_backup]

  # 保険: --storage-class を付け忘れて STANDARD で入ったものも Deep Archive へ落とす
  rule {
    id     = "transition-to-deep-archive"
    status = "Enabled"
    filter {}

    transition {
      days          = 0
      storage_class = "DEEP_ARCHIVE"
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.homehub_backup_noncurrent_retention_days
    }
  }

  rule {
    id     = "cleanup"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

# HTTPS 以外を拒否
resource "aws_s3_bucket_policy" "homehub_backup" {
  bucket     = aws_s3_bucket.homehub_backup.id
  depends_on = [aws_s3_bucket_public_access_block.homehub_backup]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.homehub_backup.arn, "${aws_s3_bucket.homehub_backup.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---------------------------------------------------------------------------
# homehub 用の書き込み専用ユーザー
#   PutObject と ListBucket だけ許可し、Delete* と GetObject は付けない。
#   homehub が乗っ取られてもバージョニングで旧版が残り、消すことも読むこともできない。
#   ポリシー変数で自アカウント以外のバケットへの操作を拒否する（アカウント ID を書かずに済む）。
#   アクセスキーは state に秘密を残さないよう Terraform では作らず CLI で発行する。
# ---------------------------------------------------------------------------
resource "aws_iam_user" "homehub_backup" {
  name = "homehub-backup"
}

resource "aws_iam_user_policy" "homehub_backup" {
  name = "homehub-backup-write-only"
  user = aws_iam_user.homehub_backup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.homehub_backup.arn
      },
      {
        Sid    = "WriteObjects"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.homehub_backup.arn}/*"
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
