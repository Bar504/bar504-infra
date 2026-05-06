# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Terraform-managed AWS infrastructure for the bar504 organization. Currently in initial build phase.
- **IaC**: Terraform >= 1.7
- **Provider**: AWS (`ap-northeast-1` default region)
- **State backend**: S3 (`bar504-terraform-state`) + DynamoDB lock (`bar504-terraform-lock`)

## Commands

```bash
# First time only — creates S3 bucket and DynamoDB table for state
./scripts/bootstrap.sh

# Standard workflow
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init
terraform plan
terraform apply
```

## Architecture

All resources currently live in the root module (no sub-modules yet). As scope expands, extract into `modules/`.

| File | Purpose |
|------|---------|
| `providers.tf` | AWS provider, backend config, required versions |
| `main.tf` | Route 53 hosted zone, ACM certificate, DNS validation records |
| `variables.tf` | All input variables and defaults |
| `outputs.tf` | Zone ID, name servers, certificate ARN/status |
| `iam.tf` | IAM roles and policies (GitHub Actions OIDC, etc.) |
| `iam_users.tf` | IAM users |
| `cloudtrail.tf` | CloudTrail trail + CloudWatch metric filters for security events |
| `monitoring.tf` | CloudWatch alarms, SNS topics, Discord notifier Lambda, dashboard |
| `claude-proxy.tf` | Claude API proxy (Lambda + Route 53 A record for proxy.bar504.net) |
| `tsu-chiman2.tf` | tsu-chiman2 サービス用リソース |

### Importing existing AWS resources

Some resources were deployed before Terraform adoption. Use `terraform import` before running `apply`:

```bash
# Hosted zone already exists
terraform import aws_route53_zone.main <ZONE_ID>

# ACM certificate already requested (pending DNS validation)
terraform import aws_acm_certificate.main <CERTIFICATE_ARN>
```

### DNS validation flow

`aws_acm_certificate` → `aws_route53_record.cert_validation` (CNAME, auto-derived) → `aws_acm_certificate_validation` (blocks until `ISSUED`).

If the domain registrar is not Route 53, point the registrar's NS records to the values in the `route53_name_servers` output.

### CloudWatch monitoring

Alarms are deployed in two regions:

- **us-east-1**: CloudFront (requests spike, 4xx/5xx error rate, bandwidth), Route 53 DNS query spike, ACM cert expiry, Billing
- **ap-northeast-1**: CloudTrail security events (root login, console login failures)

Notifications flow via SNS → Lambda (Discord webhook).

Key alarm thresholds (tunable via `terraform.tfvars`):

| Variable | Default | Notes |
|----------|---------|-------|
| `route53_dns_query_threshold` | 1000/5min | `evaluation_periods = 2` — 10分連続超過で発火（一時スパイク除外） |
| `cloudfront_request_threshold` | 300/5min | |
| `cloudfront_bandwidth_threshold_bytes` | 524,288,000 (500 MB/5min) | |
| `billing_alarm_threshold_usd` | $10/month | |
| `acm_cert_expiry_days` | 30 days | |

## Upcoming work (suggested)

- VPC / subnets / security groups (after service architecture is decided)
- Compute layer (ECS Fargate / EC2 / Lambda — TBD)
- IAM roles and least-privilege policies
- GitHub Actions CI/CD pipeline (`terraform plan` on PR, `apply` on merge)
