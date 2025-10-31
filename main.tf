#================================
# 1. Take existing Route 53 zone
#================================

data "aws_route53_zone" "cname_record" {
  name = var.domain_name
}

#================================
# 2. Create ACM certificate
#================================

resource "aws_acm_certificate" "dns_cert" {
    domain_name       = "*.${var.domain_name}"
    subject_alternative_names = [var.domain_name]
    validation_method = "DNS"
    provider = aws.acm
    lifecycle {
        #FOR TEST TIME
        create_before_destroy = false
    }
    tags = {
        Project= var.project_name
    }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.dns_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.cname_record.zone_id
}

resource "aws_acm_certificate_validation" "cert_validation" {
    certificate_arn = aws_acm_certificate.dns_cert.arn
    provider = aws.acm
    validation_record_fqdns = [ for record in aws_route53_record.cert_validation : record.fqdn ]
}


#================================
# 2. Create ACM for API
#================================
resource "aws_acm_certificate" "dns_cert_eu" {
    domain_name       = "api.${var.domain_name}"
    validation_method = "DNS"
    lifecycle {
        #FOR TEST TIME
        create_before_destroy = false
    }
    tags = {
        Project= var.project_name
    }
}



resource "aws_route53_record" "cert_validation_eu" {
  for_each = {
    for dvo in aws_acm_certificate.dns_cert_eu.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.cname_record.zone_id
}

resource "aws_acm_certificate_validation" "cert_validation_eu" {
    certificate_arn = aws_acm_certificate.dns_cert_eu.arn
    validation_record_fqdns = [ for record in aws_route53_record.cert_validation_eu : record.fqdn ]
}


#================================
# 2. S3 Bucket for static page files
#================================
module "s3-bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.8.2"

  bucket = "${var.project_name}-bucket"

  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}
module "sqs" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "5.1.0"
  name = "${var.project_name}-sqs"
  delay_seconds = 0
  fifo_queue = false
}

module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "5.0.1"
  aliases = ["${var.domain_name}","*.${var.domain_name}"]
  enabled = true
  is_ipv6_enabled = true
  comment = "Cloudfront for ${var.project_name}"
  price_class = "PriceClass_100"
  default_root_object = "index.html"

  create_origin_access_control = true
  origin_access_control = {
    s3_oac = {
      description = "Cloudfront access to S3 bucket"
      origin_type = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  origin = {
    s3_origin = {
        domain_name = module.s3-bucket.s3_bucket_bucket_regional_domain_name
        origin_access_control = "s3_oac"
        }
    }
  
  default_cache_behavior = {
    allowed_methods = ["GET","HEAD"]
    cached_methods = ["GET","HEAD"]
    target_origin_id = "s3_origin"
    compress = true
    viewer_protocol_policy = "redirect-to-https"
  }
  viewer_certificate = {
    acm_certificate_arn = aws_acm_certificate.dns_cert.arn
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  depends_on = [ aws_acm_certificate_validation.cert_validation, module.s3-bucket ]
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = module.s3-bucket.s3_bucket_id
  policy = data.aws_iam_policy_document.s3_bucket_policy.json
  depends_on = [ module.cloudfront ]
}

data "aws_iam_policy_document" "s3_bucket_policy" {
  statement {
    sid = "AllowCloudFrontServicePrincipal"
    effect = "Allow"
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

resource "aws_apigatewayv2_domain_name" "api_domain" {
  domain_name = "api.${var.domain_name}"
  domain_name_configuration {
    certificate_arn = aws_acm_certificate.dns_cert_eu.arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
  depends_on = [ aws_acm_certificate_validation.cert_validation ]
}
resource "aws_apigatewayv2_api_mapping" "api_mapping" {
  api_id = module.apigateway-v2.api_id
  domain_name = aws_apigatewayv2_domain_name.api_domain.domain_name
  stage = "$default"
}

resource "aws_route53_record" "root" {
    zone_id = data.aws_route53_zone.cname_record.zone_id
    name = var.domain_name
    type = "A"
    alias {
      name = module.cloudfront.cloudfront_distribution_domain_name
      zone_id = module.cloudfront.cloudfront_distribution_hosted_zone_id
      evaluate_target_health = false
    }
}

resource "aws_route53_record" "api_record" {
    zone_id = data.aws_route53_zone.cname_record.zone_id
    name = "api.${var.domain_name}"
    type = "A"
    alias {
      name = aws_apigatewayv2_domain_name.api_domain.domain_name_configuration[0].target_domain_name
      zone_id = aws_apigatewayv2_domain_name.api_domain.domain_name_configuration[0].hosted_zone_id
      evaluate_target_health = false
    }
}
resource "aws_route53_record" "www" {
    zone_id = data.aws_route53_zone.cname_record.zone_id
    name = "www.${var.domain_name}"
    type = "A"
    alias {
      name = module.cloudfront.cloudfront_distribution_domain_name
      zone_id = module.cloudfront.cloudfront_distribution_hosted_zone_id
      evaluate_target_health = false
    }
}

resource "aws_s3_object" "index" {
  bucket = module.s3-bucket.s3_bucket_id
  key = "index.html"
  source = "${path.module}/index.html"
  content_type = "text/html"
  etag = filemd5("${path.module}/index.html")

  depends_on = [ aws_s3_bucket_policy.bucket_policy ]
}


#================================
# 2. Lambda & IAM Role
#================================

data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    sid = "LambdaAssumeRole"
    actions = ["sts:AssumeRole"]
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json
}

resource "aws_iam_role" "lambda_ses" {
  name = "${var.project_name}-lambda-ses"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json
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
          "logs:PutLogEvents",
          "ses:SendEmail",
          "ses:SendRawEmail",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = "*"
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
          "logs:PutLogEvents",
          "ses:SendEmail",
          "ses:SendRawEmail",
          "sqs:SendMessage"
        ]
        Resource = "*"
      }
    ]
  })
}


data "archive_file" "sqs_lambda" {
  type = "zip"
  source_file = "${path.module}/sqs.py"
  output_path = "${path.module}/sqs.zip"
}
resource "aws_lambda_function" "sqs_send" {
  filename = data.archive_file.sqs_lambda.output_path
  function_name = "${var.project_name}-sqs-lambda"
  role = aws_iam_role.lambda_role.arn
  handler = "sqs.lambda_handler"
  runtime = "python3.12"
  source_code_hash = data.archive_file.sqs_lambda.output_base64sha256
  depends_on = [ aws_iam_role.lambda_role, aws_iam_role_policy.lambda_policy ]
  
  environment {
    variables = {
      "SQS_QUEUE_URL" = module.sqs.queue_url
    }
  }
}

#================================
# 2. API Gateway
#================================
module "apigateway-v2" {
  source  = "terraform-aws-modules/apigateway-v2/aws"
  version = "5.4.1"
  name = "${var.project_name}-api"
  description = "API for ${var.project_name}"
  protocol_type = "HTTP"
  create_domain_name = false
  create_domain_records = false

  cors_configuration = {
    allow_headers = ["content-type", "x-amz-date", "authorization", "origin", "accept", "access-control-allow-headers"]
    allow_methods = ["POST", "OPTIONS"]
    allow_origins = ["*"]
  }
  routes = {
    "POST /contact" = {
      integration = {
        uri = aws_lambda_function.sqs_send.invoke_arn
        payload_format_version = "2.0"
        timeout_miliseconds = 12000
      }
    }
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sqs_send.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn = "${module.apigateway-v2.api_execution_arn}/*/*"
}

data "archive_file" "lambda_ses" {
  type = "zip"
  source_file = "${path.module}/lambda_ses.py"
  output_path = "${path.module}/lambda_ses.zip"
}

resource "aws_lambda_function" "ses_sender" {
  filename = data.archive_file.lambda_ses.output_path
  function_name = "${var.project_name}-lambda-ses"
  role = aws_iam_role.lambda_ses.arn
  handler = "lambda_ses.lambda_handler"
  runtime = "python3.12"
  source_code_hash = data.archive_file.lambda_ses.output_base64sha256
  depends_on = [ aws_iam_role.lambda_ses, aws_iam_role_policy.lambda_ses_policy ]
  environment {
    variables = {
      "RECIPIENT_MAIL" = var.recipient_mail
    }
  }
}

  resource "aws_lambda_event_source_mapping" "sqs_trigger" {
    event_source_arn = module.sqs.queue_arn
    function_name = aws_lambda_function.ses_sender.arn
    batch_size = 1
  }


