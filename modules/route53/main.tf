resource "aws_route53_record" "record" {
    zone_id = var.zone_id
    name = var.domain_name
    type = "A"
    alias {
      name = var.name
      zone_id = var.zone
      evaluate_target_health = false
    }
}