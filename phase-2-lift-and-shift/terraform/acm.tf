# ACM certificate and Route 53 DNS — only provisioned when var.domain is set.
# If you don't have a domain yet, leave var.domain = "" and access OrderFlow
# directly via the ALB DNS name over HTTP.

data "aws_route53_zone" "main" {
  count = var.domain != "" ? 1 : 0
  name  = var.domain
}

resource "aws_acm_certificate" "main" {
  count             = var.domain != "" ? 1 : 0
  domain_name       = "orderflow.${var.domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.project}-cert" }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.domain != "" ? {
    for dvo in aws_acm_certificate.main[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "main" {
  count                   = var.domain != "" ? 1 : 0
  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_route53_record" "app" {
  count   = var.domain != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "orderflow.${var.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
