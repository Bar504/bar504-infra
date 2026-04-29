# ---------------------------------------------------------------------------
# S3 bucket for CloudTrail logs
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "bar504-cloudtrail-logs"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Logs — CloudTrail delivery target
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/bar504"
  retention_in_days = 90
}

resource "aws_iam_role" "cloudtrail_cw" {
  name = "bar504-cloudtrail-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_cw" {
  role = aws_iam_role.cloudtrail_cw.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

# ---------------------------------------------------------------------------
# CloudTrail — multi-region trail with log integrity validation
# ---------------------------------------------------------------------------
resource "aws_cloudtrail" "main" {
  name                          = "bar504-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_cw.arn

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ---------------------------------------------------------------------------
# Metric filters — security events (published to bar504/Security namespace)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "root_login" {
  name           = "bar504-root-login"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ $.userIdentity.type = \"Root\" && $.eventType = \"AwsConsoleSignIn\" }"

  metric_transformation {
    name          = "RootLogin"
    namespace     = "bar504/Security"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "console_login_failures" {
  name           = "bar504-console-login-failures"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ $.eventName = \"ConsoleLogin\" && $.responseElements.ConsoleLogin = \"Failure\" }"

  metric_transformation {
    name          = "ConsoleLoginFailures"
    namespace     = "bar504/Security"
    value         = "1"
    default_value = "0"
  }
}

# ---------------------------------------------------------------------------
# Security alarms — ap-northeast-1 (where CloudTrail log group lives)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "root_login" {
  alarm_name          = "security-root-account-login"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RootLogin"
  namespace           = "bar504/Security"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Root account console login detected"
  alarm_actions       = [aws_sns_topic.alerts_apne1.arn]
  ok_actions          = [aws_sns_topic.alerts_apne1.arn]
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "console_login_failures" {
  alarm_name          = "security-console-login-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ConsoleLoginFailures"
  namespace           = "bar504/Security"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Multiple console login failures — possible brute force (>5 in 5min)"
  alarm_actions       = [aws_sns_topic.alerts_apne1.arn]
  ok_actions          = [aws_sns_topic.alerts_apne1.arn]
  treat_missing_data  = "notBreaching"
}
