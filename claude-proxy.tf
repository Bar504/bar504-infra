# ---------------------------------------------------------------------------
# Route 53 A Record — proxy.bar504.net
# ---------------------------------------------------------------------------

resource "aws_route53_record" "claude_proxy" {
  count   = var.claude_proxy_ip_address != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "proxy.${var.domain_name}"
  type    = "A"
  ttl     = 300 # 5 minutes — allows re-pointing within 5 min if VPS IP changes
  records = [var.claude_proxy_ip_address]
}
