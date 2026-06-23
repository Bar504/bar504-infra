# ---------------------------------------------------------------------------
# Chiikawa Collection App
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Cognito (既存ユーザープールを参照 + 新規 App Client)
# ---------------------------------------------------------------------------
data "aws_cognito_user_pools" "chiikawa" {
  name = "TaskManager-prod"
}

resource "aws_cognito_user_pool_client" "chiikawa" {
  name         = "ChiikawaClient"
  user_pool_id = tolist(data.aws_cognito_user_pools.chiikawa.ids)[0]

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
}

# ---------------------------------------------------------------------------
# S3: 静的サイト (CloudFront OAC 専用)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "chiikawa_static" {
  bucket = "chiikawa-static-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "chiikawa_static" {
  bucket                  = aws_s3_bucket.chiikawa_static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "chiikawa_static" {
  bucket = aws_s3_bucket.chiikawa_static.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "chiikawa_static" {
  bucket = aws_s3_bucket.chiikawa_static.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.chiikawa_static.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.chiikawa.arn
          }
        }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.chiikawa_static]
}

# ---------------------------------------------------------------------------
# S3: スクレイプ画像保存用
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "chiikawa_images" {
  bucket = "chiikawa-images-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "chiikawa_images" {
  bucket                  = aws_s3_bucket.chiikawa_images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront OAC で画像バケットも配信する
resource "aws_s3_bucket_policy" "chiikawa_images" {
  bucket = aws_s3_bucket.chiikawa_images.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.chiikawa_images.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.chiikawa.arn
          }
        }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.chiikawa_images]
}

# ---------------------------------------------------------------------------
# CloudFront OAC
# ---------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "chiikawa" {
  name                              = "chiikawa-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ---------------------------------------------------------------------------
# CloudFront Distribution
# ---------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "chiikawa" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = ["chiikawa.${var.domain_name}"]
  price_class         = "PriceClass_200"

  # Origin 1: 静的サイト
  origin {
    origin_id                = "chiikawa-static"
    domain_name              = aws_s3_bucket.chiikawa_static.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.chiikawa.id
  }

  # Origin 2: 画像バケット
  origin {
    origin_id                = "chiikawa-images"
    domain_name              = aws_s3_bucket.chiikawa_images.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.chiikawa.id
  }

  # デフォルト: 静的サイト
  default_cache_behavior {
    target_origin_id       = "chiikawa-static"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  # /images/* → 画像バケット
  ordered_cache_behavior {
    path_pattern           = "/images/*"
    target_origin_id       = "chiikawa-images"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cloudfront.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# ---------------------------------------------------------------------------
# Route 53
# ---------------------------------------------------------------------------
resource "aws_route53_record" "chiikawa" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "chiikawa.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.chiikawa.domain_name
    zone_id                = aws_cloudfront_distribution.chiikawa.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "chiikawa_aaaa" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "chiikawa.${var.domain_name}"
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.chiikawa.domain_name
    zone_id                = aws_cloudfront_distribution.chiikawa.hosted_zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# DynamoDB
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "chiikawa_master" {
  name         = "ChiikawaMaster"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "Category"
  range_key    = "ItemName"

  attribute {
    name = "Category"
    type = "S"
  }

  attribute {
    name = "ItemName"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "user_collection" {
  name         = "UserCollection"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "FamilyID"
  range_key    = "ItemName"

  attribute {
    name = "FamilyID"
    type = "S"
  }

  attribute {
    name = "ItemName"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ---------------------------------------------------------------------------
# IAM: Lambda 実行ロール
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "chiikawa_api" {
  name = "chiikawa-api-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "chiikawa_api_basic" {
  role       = aws_iam_role.chiikawa_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "chiikawa_api_dynamodb" {
  name = "chiikawa-api-dynamodb"
  role = aws_iam_role.chiikawa_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:BatchGetItem",
        ]
        Resource = [
          aws_dynamodb_table.chiikawa_master.arn,
          aws_dynamodb_table.user_collection.arn,
        ]
      }
    ]
  })
}

resource "aws_iam_role" "chiikawa_scraper" {
  name = "chiikawa-scraper-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "chiikawa_scraper_basic" {
  role       = aws_iam_role.chiikawa_scraper.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "chiikawa_scraper_policy" {
  name = "chiikawa-scraper-policy"
  role = aws_iam_role.chiikawa_scraper.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
        ]
        Resource = [aws_dynamodb_table.chiikawa_master.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
        ]
        Resource = "${aws_s3_bucket.chiikawa_images.arn}/*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Lambda: API (TypeScript)
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "chiikawa_api" {
  function_name = "chiikawa-api"
  role          = aws_iam_role.chiikawa_api.arn
  runtime       = "nodejs20.x"
  handler       = "handler.lambdaHandler"
  filename      = "${path.module}/lambda_packages/chiikawa-api.zip"
  timeout       = 30
  memory_size   = 256

  environment {
    variables = {
      MASTER_TABLE     = aws_dynamodb_table.chiikawa_master.name
      COLLECTION_TABLE = aws_dynamodb_table.user_collection.name
      FAMILY_ID        = var.chiikawa_family_id
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_lambda_permission" "chiikawa_api_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chiikawa_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chiikawa.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Lambda: Scraper (Python)
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "chiikawa_scraper" {
  function_name = "chiikawa-scraper"
  role          = aws_iam_role.chiikawa_scraper.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  filename      = "${path.module}/lambda_packages/chiikawa-scraper.zip"
  timeout       = 300
  memory_size   = 512

  environment {
    variables = {
      MASTER_TABLE  = aws_dynamodb_table.chiikawa_master.name
      IMAGES_BUCKET = aws_s3_bucket.chiikawa_images.bucket
      TARGET_URL    = "https://www.jp-api.com/contents/NOD62/"
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_lambda_permission" "chiikawa_scraper_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chiikawa_scraper.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.chiikawa_scraper.arn
}

# ---------------------------------------------------------------------------
# EventBridge: 毎日 9:00 JST (= 00:00 UTC) にスクレイパーを起動
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "chiikawa_scraper" {
  name                = "chiikawa-scraper-daily"
  description         = "Daily scraping of chiikawa keychain products"
  schedule_expression = "cron(0 0 * * ? *)"
}

resource "aws_cloudwatch_event_target" "chiikawa_scraper" {
  rule      = aws_cloudwatch_event_rule.chiikawa_scraper.name
  target_id = "chiikawa-scraper-lambda"
  arn       = aws_lambda_function.chiikawa_scraper.arn
}

# ---------------------------------------------------------------------------
# API Gateway HTTP API
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "chiikawa" {
  name          = "chiikawa-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://chiikawa.${var.domain_name}"]
    allow_methods = ["GET", "PUT", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "chiikawa" {
  api_id      = aws_apigatewayv2_api.chiikawa.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_authorizer" "chiikawa_cognito" {
  api_id           = aws_apigatewayv2_api.chiikawa.id
  authorizer_type  = "JWT"
  name             = "cognito-authorizer"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.chiikawa.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${tolist(data.aws_cognito_user_pools.chiikawa.ids)[0]}"
  }
}

resource "aws_apigatewayv2_integration" "chiikawa_api" {
  api_id                 = aws_apigatewayv2_api.chiikawa.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.chiikawa_api.invoke_arn
  payload_format_version = "2.0"
}

locals {
  chiikawa_routes = {
    "GET /items"                      = {}
    "GET /items/pending"              = {}
    "PUT /items/{itemName}/status"    = {}
    "PUT /items/{itemName}/verify"    = {}
  }
}

resource "aws_apigatewayv2_route" "chiikawa" {
  for_each = local.chiikawa_routes

  api_id             = aws_apigatewayv2_api.chiikawa.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.chiikawa_api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.chiikawa_cognito.id
}

# ---------------------------------------------------------------------------
# CloudFront Cache Policy (既存 data source を再利用)
# tsu-chiman2.tf で定義済みの data.aws_cloudfront_cache_policy.caching_optimized を使用
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# SSM Parameter Store — CI/CD が GitHub Secrets なしで値を参照できるようにする
# CloudFormation Export と同等のパターン
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "chiikawa_api_url" {
  name  = "/chiikawa/api-url"
  type  = "String"
  value = aws_apigatewayv2_api.chiikawa.api_endpoint
}

resource "aws_ssm_parameter" "chiikawa_cognito_user_pool_id" {
  name  = "/chiikawa/cognito-user-pool-id"
  type  = "String"
  value = tolist(data.aws_cognito_user_pools.chiikawa.ids)[0]
}

resource "aws_ssm_parameter" "chiikawa_cognito_client_id" {
  name  = "/chiikawa/cognito-client-id"
  type  = "String"
  value = aws_cognito_user_pool_client.chiikawa.id
}

resource "aws_ssm_parameter" "chiikawa_cloudfront_url" {
  name  = "/chiikawa/cloudfront-url"
  type  = "String"
  value = "https://chiikawa.${var.domain_name}"
}

resource "aws_ssm_parameter" "chiikawa_cloudfront_distribution_id" {
  name  = "/chiikawa/cloudfront-distribution-id"
  type  = "String"
  value = aws_cloudfront_distribution.chiikawa.id
}

resource "aws_ssm_parameter" "chiikawa_static_bucket" {
  name  = "/chiikawa/static-bucket"
  type  = "String"
  value = aws_s3_bucket.chiikawa_static.bucket
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "chiikawa_cloudfront_url" {
  description = "ちいかわコレクション CloudFront URL"
  value       = "https://chiikawa.${var.domain_name}"
}

output "chiikawa_api_endpoint" {
  description = "ちいかわ API Gateway エンドポイント"
  value       = aws_apigatewayv2_api.chiikawa.api_endpoint
}

output "chiikawa_static_bucket" {
  description = "静的サイト S3 バケット名"
  value       = aws_s3_bucket.chiikawa_static.bucket
}

output "chiikawa_images_bucket" {
  description = "画像 S3 バケット名"
  value       = aws_s3_bucket.chiikawa_images.bucket
}

output "chiikawa_cognito_client_id" {
  description = "Cognito App Client ID"
  value       = aws_cognito_user_pool_client.chiikawa.id
}
