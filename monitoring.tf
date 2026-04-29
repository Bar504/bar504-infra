# ---------------------------------------------------------------------------
# Discord notifier Lambda — IAM role (IAM is global, no region needed)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "discord_notifier" {
  name = "bar504-discord-notifier"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "discord_notifier" {
  role       = aws_iam_role.discord_notifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ---------------------------------------------------------------------------
# Lambda deployment package (inline Python, no external files needed)
# ---------------------------------------------------------------------------
data "archive_file" "discord_notifier" {
  type        = "zip"
  output_path = "${path.module}/discord_notifier.zip"

  source {
    filename = "handler.py"
    content  = <<-PYTHON
import json
import os
import urllib.request

COLORS = {
    "ALARM": 15158332,
    "OK": 3066993,
    "INSUFFICIENT_DATA": 10070709,
}

def handler(event, context):
    webhook_url = os.environ["DISCORD_WEBHOOK_URL"]
    for record in event["Records"]:
        msg = record["Sns"]
        try:
            body   = json.loads(msg["Message"])
            state  = body.get("NewStateValue", "")
            alarm  = body.get("AlarmName", msg.get("Subject", "Alarm"))
            reason = body.get("NewStateReason", "")
        except (json.JSONDecodeError, KeyError):
            state  = ""
            alarm  = msg.get("Subject", "CloudWatch Alarm")
            reason = msg.get("Message", "")

        payload = {
            "embeds": [{
                "title": alarm,
                "description": reason[:2048],
                "color": COLORS.get(state, 10070709),
                "fields": [{"name": "State", "value": state or "UNKNOWN", "inline": True}],
            }]
        }
        data = json.dumps(payload).encode()
        req  = urllib.request.Request(
            webhook_url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req)
PYTHON
  }
}

# ---------------------------------------------------------------------------
# SNS + Lambda — us-east-1
# (CloudFront / Route 53 / ACM / Billing metrics all publish here)
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts_use1" {
  provider = aws.us_east_1
  name     = "bar504-cloudwatch-alerts"
}

resource "aws_lambda_function" "discord_notifier_use1" {
  provider         = aws.us_east_1
  function_name    = "bar504-discord-notifier"
  role             = aws_iam_role.discord_notifier.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.discord_notifier.output_path
  source_code_hash = data.archive_file.discord_notifier.output_base64sha256

  environment {
    variables = {
      DISCORD_WEBHOOK_URL = var.discord_webhook_url
    }
  }
}

resource "aws_lambda_permission" "sns_invoke_use1" {
  provider      = aws.us_east_1
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord_notifier_use1.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts_use1.arn
}

resource "aws_sns_topic_subscription" "discord_use1" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.alerts_use1.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.discord_notifier_use1.arn
}

# ---------------------------------------------------------------------------
# SNS + Lambda — ap-northeast-1
# (CloudTrail security metric filters publish here)
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts_apne1" {
  name = "bar504-cloudwatch-alerts"
}

resource "aws_lambda_function" "discord_notifier_apne1" {
  function_name    = "bar504-discord-notifier"
  role             = aws_iam_role.discord_notifier.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.discord_notifier.output_path
  source_code_hash = data.archive_file.discord_notifier.output_base64sha256

  environment {
    variables = {
      DISCORD_WEBHOOK_URL = var.discord_webhook_url
    }
  }
}

resource "aws_lambda_permission" "sns_invoke_apne1" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord_notifier_apne1.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts_apne1.arn
}

resource "aws_sns_topic_subscription" "discord_apne1" {
  topic_arn = aws_sns_topic.alerts_apne1.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.discord_notifier_apne1.arn
}

# ---------------------------------------------------------------------------
# CloudFront alarms — one set per distribution via for_each
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "cf_requests" {
  for_each            = var.cloudfront_distribution_ids
  provider            = aws.us_east_1
  alarm_name          = "cloudfront-${each.key}-requests-spike"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Requests"
  namespace           = "AWS/CloudFront"
  period              = 300
  statistic           = "Sum"
  threshold           = var.cloudfront_request_threshold
  alarm_description   = "[${each.key}] CloudFront requests exceeded ${var.cloudfront_request_threshold}/5min — possible attack"
  alarm_actions       = [aws_sns_topic.alerts_use1.arn]
  ok_actions          = [aws_sns_topic.alerts_use1.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = each.value
    Region         = "Global"
  }
}

resource "aws_cloudwatch_metric_alarm" "cf_4xx" {
  for_each            = var.cloudfront_distribution_ids
  provider            = aws.us_east_1
  alarm_name          = "cloudfront-${each.key}-4xx-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "4xxErrorRate"
  namespace           = "AWS/CloudFront"
  period              = 300
  statistic           = "Average"
  threshold           = 25
  alarm_description   = "[${each.key}] High 4xx rate — possible path scanning or brute force (>25% over 10min)"
  alarm_actions       = [aws_sns_topic.alerts_use1.arn]
  ok_actions          = [aws_sns_topic.alerts_use1.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = each.value
    Region         = "Global"
  }
}

resource "aws_cloudwatch_metric_alarm" "cf_5xx" {
  for_each            = var.cloudfront_distribution_ids
  provider            = aws.us_east_1
  alarm_name          = "cloudfront-${each.key}-5xx-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5xxErrorRate"
  namespace           = "AWS/CloudFront"
  period              = 300
  statistic           = "Average"
  threshold           = 5
  alarm_description   = "[${each.key}] High 5xx rate — origin health issue (>5% over 10min)"
  alarm_actions       = [aws_sns_topic.alerts_use1.arn]
  ok_actions          = [aws_sns_topic.alerts_use1.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = each.value
    Region         = "Global"
  }
}

resource "aws_cloudwatch_metric_alarm" "cf_bandwidth" {
  for_each            = var.cloudfront_distribution_ids
  provider            = aws.us_east_1
  alarm_name          = "cloudfront-${each.key}-bandwidth-spike"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BytesDownloaded"
  namespace           = "AWS/CloudFront"
  period              = 300
  statistic           = "Sum"
  threshold           = var.cloudfront_bandwidth_threshold_bytes
  alarm_description   = "[${each.key}] Bandwidth spike — possible DDoS or data exfiltration"
  alarm_actions       = [aws_sns_topic.alerts_use1.arn]
  ok_actions          = [aws_sns_topic.alerts_use1.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = each.value
    Region         = "Global"
  }
}

# ---------------------------------------------------------------------------
# Route 53 — DNS query spike
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "r53_dns_queries" {
  provider            = aws.us_east_1
  alarm_name          = "route53-dns-query-spike"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DNSQueries"
  namespace           = "AWS/Route53"
  period              = 300
  statistic           = "Sum"
  threshold           = var.route53_dns_query_threshold
  alarm_description   = "Route 53 DNS query spike — possible DNS amplification or reconnaissance"
  alarm_actions       = [aws_sns_topic.alerts_use1.arn]
  ok_actions          = [aws_sns_topic.alerts_use1.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    HostedZoneId = data.aws_route53_zone.main.zone_id
  }
}

# ---------------------------------------------------------------------------
# ACM certificate expiry
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "acm_expiry_tokyo" {
  provider            = aws.us_east_1
  alarm_name          = "acm-cert-expiry-tokyo"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DaysToExpiry"
  namespace           = "AWS/CertificateManager"
  period              = 86400
  statistic           = "Minimum"
  threshold           = var.acm_cert_expiry_days
  alarm_description   = "ACM certificate (Tokyo/ALB) expires in <${var.acm_cert_expiry_days} days"
  alarm_actions       = [aws_sns_topic.alerts_use1.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    CertificateArn = aws_acm_certificate.main.arn
  }
}

resource "aws_cloudwatch_metric_alarm" "acm_expiry_cloudfront" {
  provider            = aws.us_east_1
  alarm_name          = "acm-cert-expiry-cloudfront"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DaysToExpiry"
  namespace           = "AWS/CertificateManager"
  period              = 86400
  statistic           = "Minimum"
  threshold           = var.acm_cert_expiry_days
  alarm_description   = "ACM certificate (CloudFront) expires in <${var.acm_cert_expiry_days} days"
  alarm_actions       = [aws_sns_topic.alerts_use1.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    CertificateArn = aws_acm_certificate.cloudfront.arn
  }
}

# ---------------------------------------------------------------------------
# Billing — unexpected cost spike
# NOTE: Enable "Receive Billing Alerts" in AWS Billing console before applying
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "billing" {
  provider            = aws.us_east_1
  alarm_name          = "billing-estimated-charges"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 86400
  statistic           = "Maximum"
  threshold           = var.billing_alarm_threshold_usd
  alarm_description   = "Monthly estimated AWS charges exceeded $${var.billing_alarm_threshold_usd} USD"
  alarm_actions       = [aws_sns_topic.alerts_use1.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency = "USD"
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  provider       = aws.us_east_1
  dashboard_name = "bar504-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# bar504 Infrastructure\nCloudFront attack detection · Route 53 DNS · ACM cert expiry · Security events · Billing"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title   = "CloudFront — Requests / 5min"
          region  = "us-east-1"
          view    = "timeSeries"
          period  = 300
          stat    = "Sum"
          metrics = [for name, id in var.cloudfront_distribution_ids :
            ["AWS/CloudFront", "Requests", "DistributionId", id, "Region", "Global", { label = name }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title   = "CloudFront — Bandwidth Downloaded / 5min"
          region  = "us-east-1"
          view    = "timeSeries"
          period  = 300
          stat    = "Sum"
          metrics = [for name, id in var.cloudfront_distribution_ids :
            ["AWS/CloudFront", "BytesDownloaded", "DistributionId", id, "Region", "Global", { label = name }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "CloudFront — Error Rates"
          region  = "us-east-1"
          view    = "timeSeries"
          period  = 300
          stat    = "Average"
          metrics = concat(
            [for name, id in var.cloudfront_distribution_ids :
              ["AWS/CloudFront", "4xxErrorRate", "DistributionId", id, "Region", "Global", { label = "${name} 4xx" }]
            ],
            [for name, id in var.cloudfront_distribution_ids :
              ["AWS/CloudFront", "5xxErrorRate", "DistributionId", id, "Region", "Global", { label = "${name} 5xx" }]
            ]
          )
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "Route 53 — DNS Queries / 5min"
          region  = "us-east-1"
          view    = "timeSeries"
          period  = 300
          stat    = "Sum"
          metrics = [
            ["AWS/Route53", "DNSQueries", "HostedZoneId", data.aws_route53_zone.main.zone_id]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "Security — Root Login & Failed Console Logins"
          region  = "ap-northeast-1"
          view    = "timeSeries"
          period  = 300
          stat    = "Sum"
          metrics = [
            ["bar504/Security", "RootLogin"],
            ["bar504/Security", "ConsoleLoginFailures"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "Billing — Estimated Charges (USD)"
          region  = "us-east-1"
          view    = "timeSeries"
          period  = 86400
          stat    = "Maximum"
          metrics = [
            ["AWS/Billing", "EstimatedCharges", "Currency", "USD"]
          ]
        }
      },
    ]
  })
}
