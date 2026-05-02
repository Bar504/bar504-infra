# ---------------------------------------------------------------------------
# Route 53 A Record — proxy.bar504.net (Claude reverse proxy on VPS)
# ---------------------------------------------------------------------------

resource "aws_route53_record" "claude_proxy" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "proxy.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [var.claude_proxy_ip_address]
}
