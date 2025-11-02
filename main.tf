data "aws_route53_zone" "cname_record" {
  name = var.domain_name
}

module "acm_website" {
  source = "./modules/acm"
  domain_name = "${var.domain_name}"
  project_name = var.project_name
  zone_id = data.aws_route53_zone.cname_record.zone_id
  providers = {
    aws = aws.useast
  }
}

module "acm_api" {
  source = "./modules/acm"
  domain_name = "api.${var.domain_name}"
  project_name = var.project_name
  zone_id = data.aws_route53_zone.cname_record.zone_id
  providers = {
    aws = aws.eucentral
  }
}

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
  aliases = ["${var.domain_name}"]
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
    acm_certificate_arn = module.acm_website.certificate_arn
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  depends_on = [ module.acm_website ]
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

module "api_gateway_mapping" {
  source = "./modules/api_gateway"
  domain_name = var.domain_name
  acm_api = module.acm_api.certificate_arn
  apigateway-v2 = module.apigatewayv2.api_id
}

module "r53_root" {
  source = "./modules/route53"
  domain_name = var.domain_name
  name = module.cloudfront.cloudfront_distribution_domain_name
  zone_id = data.aws_route53_zone.cname_record.zone_id
  zone = module.cloudfront.cloudfront_distribution_hosted_zone_id
  evaluate_target_health = false
}
module "r53_api" {
  source = "./modules/route53"
  domain_name = "api.${var.domain_name}"
  name = module.api_gateway_mapping.domain_name_target
  zone_id = data.aws_route53_zone.cname_record.zone_id
  zone = module.api_gateway_mapping.domain_name_zone_id
  evaluate_target_health = false
}
module "r53_www" {
  source = "./modules/route53"
  domain_name = "www.${var.domain_name}"
  name = module.cloudfront.cloudfront_distribution_domain_name
  zone_id = data.aws_route53_zone.cname_record.zone_id
  zone = module.cloudfront.cloudfront_distribution_hosted_zone_id
  evaluate_target_health = false
}

resource "aws_s3_object" "index" {
  bucket = module.s3-bucket.s3_bucket_id
  key = "index.html"
  source = "${path.module}/src/website/index.html"
  content_type = "text/html"
  etag = filemd5("${path.module}/src/website/index.html")

  depends_on = [ aws_s3_bucket_policy.bucket_policy ]
}

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
  source_file = "${path.module}/src/lambda/sqs.py"
  output_path = "${path.module}/src/lambda/sqs.zip"
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

module "apigatewayv2" {
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
  source_arn = "${module.apigatewayv2.api_execution_arn}/*/*"
}

data "archive_file" "lambda_ses" {
  type = "zip"
  source_file = "${path.module}/src/lambda/lambda_ses.py"
  output_path = "${path.module}/src/lambda/lambda_ses.zip"
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

# Tymczasowo zakomentowane z powodu konfliktu wersji AWS providera
# module "bedrock_aibot" {
#   source  = "aws-ia/bedrock/aws"
#   version = "0.0.31"
#   foundation_model = "anthropic.claude-3-haiku-20240307-v1:0"
#   create_guardrail = true
#   blocked_input_messaging = "Przykro mi, mogę udzielać informacji tylko dotyczących Piotra Itman."
#   blocked_outputs_messaging = "Przykro mi, mogę udzielać informacji tylko dotyczących Piotra Itman."
#   filters_config = [
#     {
#       input_strength = "MEDIUM"
#       output_strength = "MEDIUM"
#       type = "HATE"
#     },
#     {
#       input_strength = "HIGH"
#       output_strength = "HIGH"
#       type = "SENSITIVE"
#     },
#     {
#     input_strength = "HIGH"
#     output_strength = "HIGH"
#     type = "VIOLENCE"
#     }
#   ]
#   pii_entities_config = [
#     {
#       action = "BLOCK"
#       type = "NAME"
#     },
#     {
#       action = "BLOCK"
#       type = "ADDRESS"
#     },
#     {
#       action = "BLOCK"
#       type = "BANK_ACCOUNT_NUMBER"
#     },
#     {
#       action = "BLOCK"
#       type = "BANK_ROUTING"
#     },
#     {
#       action = "BLOCK"
#       type = "IP_ADDRESS"
#     },
#     {
#       action = "BLOCK"
#       type = "AGE"
#     },
#     {
#       action = "BLOCK"
#       type = "URL"
#     },
#     {
#       action = "BLOCK"
#       type = "ID"
#     },
#     {
#       action = "BLOCK"
#       type = "CREDIT_CARD"
#     },
#     {
#       action = "BLOCK"
#       type = "AWS_CRED"
#     },
#   ]
#   topics_config = [{
#     name = "Piotr Itman"
#     examples = ["Gdzie studiował Piotr?", "Jakie są umiejętności Piotra?", "Czy Piotr Itman zajmuję się AWS?", "Jakie certyfikaty posiada Piotrek?"]
#     type = "ALLOW"
#   },
#   {
#     name = "Porady inwestycyjne"
#     examples = ["Jakie są ceny nieruchomości?", "Jakie są ceny mieszkania?", "Jakie są ceny domu?", "Jakie są ceny apartamentu?"]
#     type = "DENY"
#     definition = "Przykro mi, mogę udzielać informacji tylko dotyczących Piotra Itman."
#   },
#   {
#     name = "Przepis na zupę"
#     examples = ["Jak zrobić zupę?", "Jak zrobić zupę na krem?", "Jak zrobić zupę na krem z mlekiem?"]
#     type = "DENY"
#     definition = "Przykro mi, mogę udzielać informacji tylko dotyczących Piotra Itman."
#   }
#   ]
#   instruction = "Jesteś asystentem, który odpowiada na pytania użytkowników związane z historią oraz danymi kandydata, o którym wszystkie informacje masz w bazie danych. Unikaj halucynacji, nie wymyślaj i trafiaj odpowiedziami na pytania w punkt. Jeśli czegoś nie wiesz - napisz: Nie mam tej informacji"
# }
