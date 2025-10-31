output "certificate_arn" {
    value = aws_acm_certificate_validation.cert_validation.certificate_arn
}
output "validation_options" {
    value = aws_acm_certificate.dns_cert.domain_validation_options
}
