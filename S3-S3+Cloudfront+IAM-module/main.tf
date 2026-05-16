data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_public_access_block" "resume" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

########## BUCKET #############
########## BUCKET #############
########## BUCKET #############
resource "aws_s3_bucket" "main" {
  bucket = "123fozchallengebucket"

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}
########## BUCKET #############
########## BUCKET #############
########## BUCKET #############

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
      values   = [aws_cloudfront_distribution.s3_distribution.arn]
      # values   = [aws_cloudfront_distribution.s3_distribution.arn, data.aws_caller_identity.current.account_id]
    }
  }
}

##########
resource "aws_s3_bucket_policy" "s3_policy" {
  bucket = aws_s3_bucket.main.id
  policy = data.aws_iam_policy_document.s3_policy.json

  depends_on = [
    aws_cloudfront_distribution.s3_distribution
  ]
}

################# CLOUDFRONT RESOURCES #######################

resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name                              = "s3_oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_object" "style" {
  bucket       = aws_s3_bucket.main.id
  key          = "style.css"
  source       = "website/style.css"
  content_type = "text/css"
  etag         = filemd5("website/style.css")
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.main.id
  key          = "index.html"
  source       = "website/index.html"
  content_type = "text/html"
  etag         = filemd5("website/index.html")
}

####### cloudfront distribution #########

resource "aws_cloudfront_distribution" "s3_distribution" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  comment             = "Resume site with visitor counter"

  # ==================== S3 Origin ====================
  origin {
    domain_name              = aws_s3_bucket.main.bucket_regional_domain_name
    origin_id                = "s3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
  }

  # ==================== Lambda Origin ====================
  origin {
    domain_name = trim(replace(aws_lambda_function_url.visitor_counter.function_url, "https://", ""), "/")
    origin_id   = "lambdaOrigin"
    # origin_access_control_id = aws_cloudfront_origin_access_control.lambda_oac.id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ==================== Default Behavior (S3) ====================
  # DEFAULT behavior sends everything to S3 first
  default_cache_behavior {
    allowed_methods        = ["HEAD", "GET"]
    cached_methods         = ["HEAD", "GET"]
    target_origin_id       = "s3Origin" #to S3
    viewer_protocol_policy = "redirect-to-https"

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
  # ==================== API Behavior (/api/* → Lambda) ====================
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "lambdaOrigin"
    viewer_protocol_policy = "https-only"

    forwarded_values {
      query_string = true
      headers      = ["Origin", "Access-Control-Request-Method", "Access-Control-Request-Headers"]
      # headers      = ["Origin", "Access-Control-Request-Method", "Access-Control-Request-Headers"]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "MyDistribution"
  }


  # This ensures S3 and OAC are fully ready before CloudFront tries to validate them
  depends_on = [
    aws_s3_bucket.main,
    aws_cloudfront_origin_access_control.s3_oac
  ]
}

#### lambda resources

# # IAM role for Lambda execution
# data "aws_iam_policy_document" "assume_role" {
#   statement {
#     effect = "Allow"

#     principals {
#       type        = "Service"
#       identifiers = ["lambda.amazonaws.com"]
#     }

#     actions = ["sts:AssumeRole"]
#   }
# }

# resource "aws_iam_role" "lambda_role" {
#   name               = "lambda_execution_role"
#   assume_role_policy = data.aws_iam_policy_document.assume_role.json
# }

# Package the Lambda function code
data "archive_file" "file" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/src"
  output_path = "${path.module}/lambda/function/lambda.zip"
}

# DYNAMODB TABLE # DYNAMODB TABLE# DYNAMODB TABLE# DYNAMODB TABLE# DYNAMODB TABLE# DYNAMODB TABLE# DYNAMODB TABLE# DYNAMODB TABLE# DYNAMODB TABLE

resource "aws_dynamodb_table" "visitors" {
  name         = "visitor-count"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# Attach DynamoDB full access
resource "aws_iam_role_policy_attachment" "dynamodb_access" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2"
}

# DYNAMODB ACCESS# DYNAMODB ACCESS# DYNAMODB ACCESS# DYNAMODB ACCESS# DYNAMODB ACCESS# DYNAMODB ACCESS# DYNAMODB ACCESS# DYNAMODB ACCESS# DYNAMODB ACCESS

# Lambda function
resource "aws_lambda_function" "visitor_counter" {
  filename      = data.archive_file.file.output_path
  function_name = "visitor-counter"
  role          = aws_iam_role.lambda_role.arn
  handler       = "visitor.lambda_handler"
  code_sha256   = data.archive_file.file.output_base64sha256

  runtime = "python3.11"

  environment {
    variables = {
      ENVIRONMENT = "production"
      LOG_LEVEL   = "info"
      TABLE_NAME  = aws_dynamodb_table.visitors.name
    }
  }
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

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# IAM ROLE FOR LAMBDA
resource "aws_iam_role" "lambda_role" {
  name = "visitor-counter-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# # Attach DynamoDB full access
# resource "aws_iam_role_policy_attachment" "dynamodb_access" {
#   role       = aws_iam_role.lambda_role.name
#   policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess_v2"
# }

# # DYNAMODB TABLE
# resource "aws_dynamodb_table" "visitors" {
#   name         = "visitor-count"
#   billing_mode = "PAY_PER_REQUEST"
#   hash_key     = "id"

#   attribute {
#     name = "id"
#     type = "S"
#   }
# }
# # Automate zip
# data "archive_file" "lambda_zip" {
#   type        = "zip"
#   source_dir  = "${path.module}/lambda/src"
#   output_path = "${path.module}/lambda/function/lambda.zip"
# }

# # LAMBDA FUNCTION
# resource "aws_lambda_function" "visitor_counter" {
#   filename      = data.archive_file.lambda_zip.output_path
#   function_name = "visitor-counter"
#   role          = aws_iam_role.lambda_role.arn
#   handler       = "visitor.lambda_handler"
#   runtime       = "python3.11"

#   environment {
#     variables = {
#       TABLE_NAME = aws_dynamodb_table.visitors.name
#     }
#   }
# }

# # ============================================
# # LAMBDA FUNCTION URL (public for testing)
# # ============================================
# resource "aws_lambda_function_url" "visitor_counter" {
#   function_name      = aws_lambda_function.visitor_counter.function_name
#   authorization_type = "NONE" # public URL for testing

#   cors {
#     allow_origins = var.allowed_origin != null ? [var.allowed_origin] : ["*"]
#     allow_methods = ["GET", "POST"]
#     allow_headers = ["*"]
#     max_age       = 86400
#   }
# }

# resource "aws_iam_role_policy_attachment" "lambda_logs" {
#   role       = aws_iam_role.lambda_role.name
#   policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
# }

# resource "aws_lambda_permission" "allow_public_url" {
#   statement_id           = "FunctionUrlAllowPublicAccess"
#   action                 = "lambda:InvokeFunctionUrl"
#   function_name          = aws_lambda_function.visitor_counter.function_name
#   principal              = "*"
#   function_url_auth_type = "NONE"
# }
