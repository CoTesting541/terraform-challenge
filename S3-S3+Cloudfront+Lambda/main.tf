data "aws_caller_identity" "current" {}

#s3 buccket
resource "aws_s3_bucket" "main" {
  bucket = "my-main-bucket-12345foz"
}

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.main.bucket
  key          = "index.html"
  source       = "website/index.html"
  etag         = filemd5("website/index.html")
  content_type = "text/html"
}

resource "aws_s3_object" "css" {
  bucket       = aws_s3_bucket.main.bucket
  key          = "style.css"
  source       = "website/style.css"
  etag         = filemd5("website/style.css")
  content_type = "text/css"
}

resource "aws_s3_bucket_public_access_block" "resume" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    sid    = "AllowCloudFrontServicePrincipal"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "${aws_s3_bucket.main.arn}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.website.arn]
      # values   = [aws_cloudfront_distribution.s3_distribution.arn, data.aws_caller_identity.current.account_id]
    }
  }
}

# resource "aws_s3_bucket_policy" "main" {
#   bucket = aws_s3_bucket.main.id

#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect    = "Allow"
#         Principal = "*"
#         Action    = "s3:GetObject"
#         Resource  = "${aws_s3_bucket.main.arn}/*"
#       }
#     ]
#   })
# }

resource "aws_s3_bucket_policy" "s3_policy" {
  bucket = aws_s3_bucket.main.id
  policy = data.aws_iam_policy_document.s3_policy.json

  depends_on = [
    aws_cloudfront_distribution.website
  ]
}


# IAM role for Lambda function
resource "aws_iam_role" "lambda_exec" {
  name = "visitor-counter-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach necessary policies to the Lambda execution role

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "cloudfront_full_access" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/CloudFrontFullAccess"
}

resource "aws_iam_role_policy_attachment" "dynamodb_full_access" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2"
}

# S3 OAC and CloudFront distribution

resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name                              = "s3_oac"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
  origin_access_control_origin_type = "s3"
}

resource "aws_cloudfront_distribution" "website" {

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront distribution for S3 website"
  default_root_object = "index.html"

  # s3 origin
  origin {
    domain_name              = aws_s3_bucket.main.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
  }

  # lambda origin
  origin {
    domain_name = trim(replace(aws_lambda_function_url.visitor_counter.function_url, "https://", ""), "/")
    origin_id   = "lambda-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["HEAD", "GET"]
    cached_methods         = ["HEAD", "GET"]

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

  }

  ordered_cache_behavior {

    path_pattern           = "/api/*"
    target_origin_id       = "lambda-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0

    forwarded_values {
      query_string = true
      #   headers      = ["Origin", "Access-Control-Request-Method", "Access-Control-Request-Headers"]
      # headers      = ["Origin", "Access-Control-Request-Method", "Access-Control-Request-Headers"]
      cookies {
        forward = "none"
      }
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

  depends_on = [
    aws_s3_bucket.main,
    aws_cloudfront_origin_access_control.s3_oac
  ]

}

# Package the Lambda function code and create the Lambda function

data "archive_file" "file" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/src"
  output_path = "${path.module}/lambda/function/lambda.zip"
}

resource "aws_lambda_function" "visitor_counter" {
  function_name = "visitor-counter"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "visitor.lambda_handler"
  runtime       = "python3.11"

  filename    = data.archive_file.file.output_path
  code_sha256 = data.archive_file.file.output_base64sha256

  ## set environment variable for DynamoDB table name, not needed because the table name is hardcoded in the lambda function, 
  ## but can be used if you want to make it more dynamic
  #   environment {
  #     variables = {
  #       TABLE_NAME = aws_dynamodb_table.visitor_counter.name
  #     }
  #   }

}

resource "aws_lambda_function_url" "visitor_counter" {
  function_name      = aws_lambda_function.visitor_counter.function_name
  authorization_type = "NONE"
  cors {
    allow_credentials = false
    allow_origins     = var.allowed_origin != null ? [var.allowed_origin] : ["*"]
    allow_methods     = ["GET", "POST"]
    allow_headers     = ["*"]
    expose_headers    = ["keep-alive", "date"]
    max_age           = 86400
  }

}

resource "aws_lambda_permission" "allow_public_url" {
  statement_id           = "FunctionUrlAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.visitor_counter.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# DynamoDB table for visitor count
resource "aws_dynamodb_table" "visitor_counter" {
  name         = "visitor-count" ###### has to match lambda dynamodb table name reference
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}
