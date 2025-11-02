resource "aws_apigatewayv2_domain_name" "api_domain" {
  domain_name = "api.${var.domain_name}"
  domain_name_configuration {
    certificate_arn = var.acm_api
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}



resource "aws_apigatewayv2_api_mapping" "api_mapping" {
  api_id = var.apigateway-v2
  domain_name = aws_apigatewayv2_domain_name.api_domain.domain_name
  stage = "$default"
}
