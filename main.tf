data "aws_route53_zone" "cname_record" {
  name = var.domain_name
}

data "aws_caller_identity" "current" {}

module "acm_website" {
  source       = "./modules/acm"
  domain_name  = var.domain_name
  project_name = var.project_name
  zone_id      = data.aws_route53_zone.cname_record.zone_id
  providers = {
    aws = aws.useast
  }
}

module "acm_api" {
  source       = "./modules/acm"
  domain_name  = "api.${var.domain_name}"
  project_name = var.project_name
  zone_id      = data.aws_route53_zone.cname_record.zone_id
  providers = {
    aws = aws.eucentral
  }
}

module "s3-bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.8.2"

  bucket = "${var.project_name}-bucket"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }
}

module "sqs" {
  source        = "terraform-aws-modules/sqs/aws"
  version       = "5.1.0"
  name          = "${var.project_name}-sqs"
  delay_seconds = 0
  fifo_queue    = false
}

module "cloudfront" {
  source              = "terraform-aws-modules/cloudfront/aws"
  version             = "5.0.1"
  aliases             = ["${var.domain_name}"]
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Cloudfront for ${var.project_name}"
  price_class         = "PriceClass_100"
  default_root_object = "index.html"


  create_origin_access_control = true
  origin_access_control = {
    s3_oac = {
      description      = "Cloudfront access to S3 bucket"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  origin = {
    s3_origin = {
      domain_name           = module.s3-bucket.s3_bucket_bucket_regional_domain_name
      origin_access_control = "s3_oac"
    }
  }

  default_cache_behavior = {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3_origin"
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 20
    max_ttl                = 3600
  }
  viewer_certificate = {
    acm_certificate_arn      = module.acm_website.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  depends_on = [module.acm_website]
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket     = module.s3-bucket.s3_bucket_id
  policy     = data.aws_iam_policy_document.s3_bucket_policy.json
  depends_on = [module.cloudfront]
}

data "aws_iam_policy_document" "s3_bucket_policy" {
  statement {
    sid       = "AllowCloudFrontServicePrincipal"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.s3-bucket.s3_bucket_arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cloudfront.cloudfront_distribution_arn]
    }
  }
}

module "api_gateway_mapping" {
  source        = "./modules/api_gateway"
  domain_name   = var.domain_name
  acm_api       = module.acm_api.certificate_arn
  apigateway-v2 = module.apigatewayv2.api_id
}

module "r53_root" {
  source                 = "./modules/route53"
  domain_name            = var.domain_name
  name                   = module.cloudfront.cloudfront_distribution_domain_name
  zone_id                = data.aws_route53_zone.cname_record.zone_id
  zone                   = module.cloudfront.cloudfront_distribution_hosted_zone_id
  evaluate_target_health = false
}
module "r53_api" {
  source                 = "./modules/route53"
  domain_name            = "api.${var.domain_name}"
  name                   = module.api_gateway_mapping.domain_name_target
  zone_id                = data.aws_route53_zone.cname_record.zone_id
  zone                   = module.api_gateway_mapping.domain_name_zone_id
  evaluate_target_health = false
}
module "r53_www" {
  source                 = "./modules/route53"
  domain_name            = "www.${var.domain_name}"
  name                   = module.cloudfront.cloudfront_distribution_domain_name
  zone_id                = data.aws_route53_zone.cname_record.zone_id
  zone                   = module.cloudfront.cloudfront_distribution_hosted_zone_id
  evaluate_target_health = false
}

resource "aws_s3_object" "index" {
  bucket       = module.s3-bucket.s3_bucket_id
  key          = "index.html"
  source       = "${path.module}/src/website/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/src/website/index.html")

  depends_on = [aws_s3_bucket_policy.bucket_policy]
}

data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    sid     = "LambdaAssumeRole"
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "lambda_role" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "lambda_ses" {
  name               = "${var.project_name}-lambda-ses"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "lambda_chatbot" {
  name               = "${var.project_name}-lambda-chatbot"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "lambda_chatbot_policy" {
  name = "lambda-chatbot-policy"
  role = aws_iam_role.lambda_chatbot.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-chatbot_bedrock:*"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_ses_policy" {
  name = "lambda-ses-policy"
  role = aws_iam_role.lambda_ses.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-lambda-ses:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = module.sqs.queue_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda-inline-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-lambda-ses:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = module.sqs.queue_arn
      }
    ]
  })
}

data "archive_file" "sqs_lambda" {
  type        = "zip"
  source_file = "${path.module}/src/lambda/sqs.py"
  output_path = "${path.module}/src/lambda/sqs.zip"
}

resource "aws_lambda_function" "sqs_send" {
  filename         = data.archive_file.sqs_lambda.output_path
  function_name    = "${var.project_name}-sqs-lambda"
  role             = aws_iam_role.lambda_role.arn
  handler          = "sqs.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.sqs_lambda.output_base64sha256

  tracing_config {
    mode = "Active"
  }
  environment {
    variables = {
      "SQS_QUEUE_URL" = module.sqs.queue_url
    }
  }
}

module "apigatewayv2" {
  source                = "terraform-aws-modules/apigateway-v2/aws"
  version               = "5.4.1"
  name                  = "${var.project_name}-api"
  description           = "API for ${var.project_name}"
  protocol_type         = "HTTP"
  create_domain_name    = false
  create_domain_records = false

  create_stage = true
  stage_name   = "$default"

  cors_configuration = {
    allow_headers = ["content-type", "x-amz-date", "authorization", "origin", "accept", "access-control-allow-headers"]
    allow_methods = ["POST", "OPTIONS"]
    allow_origins = ["*"]
  }
  routes = {
    "POST /contact" = {
      integration = {
        uri                    = aws_lambda_function.sqs_send.invoke_arn
        payload_format_version = "2.0"
        timeout_miliseconds    = 12000
      }
    }
    "POST /chat" = {
      integration = {
        uri                    = aws_lambda_function.chatbot.invoke_arn
        payload_format_version = "2.0"
        timeout_miliseconds    = 12000
      }
    }
  }
}
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sqs_send.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.apigatewayv2.api_execution_arn}/*/*"
}

data "archive_file" "lambda_ses" {
  type        = "zip"
  source_file = "${path.module}/src/lambda/lambda_ses.py"
  output_path = "${path.module}/src/lambda/lambda_ses.zip"
}

resource "aws_lambda_function" "ses_sender" {
  filename         = data.archive_file.lambda_ses.output_path
  function_name    = "${var.project_name}-lambda-ses"
  role             = aws_iam_role.lambda_ses.arn
  handler          = "lambda_ses.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.lambda_ses.output_base64sha256

  tracing_config {
    mode = "Active"
  }
  environment {
    variables = {
      "RECIPIENT_MAIL" = var.recipient_mail
    }
  }
}
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = module.sqs.queue_arn
  function_name    = aws_lambda_function.ses_sender.arn
  batch_size       = 1
}
data "archive_file" "chatbot" {
  type        = "zip"
  source_file = "${path.module}/src/lambda/chatbot_bedrock.py"
  output_path = "${path.module}/src/lambda/chatbot_bedrock.zip"
}
resource "aws_lambda_function" "chatbot" {
  filename         = data.archive_file.chatbot.output_path
  function_name    = "${var.project_name}-chatbot_bedrock"
  role             = aws_iam_role.lambda_chatbot.arn
  handler          = "chatbot_bedrock.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.chatbot.output_base64sha256
  tracing_config {
    mode = "Active"
  }

}

resource "aws_lambda_permission" "apigw_chatbot" {
  statement_id  = "AllowExecutionFromAPIGatewayChatbot"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chatbot.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.apigatewayv2.api_execution_arn}/*/*"
}


