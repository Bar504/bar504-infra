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
| `variables.tf` | `aws_region`, `domain_name` |
| `outputs.tf` | Zone ID, name servers, certificate ARN/status |

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

## Upcoming work (suggested)

- VPC / subnets / security groups (after service architecture is decided)
- Compute layer (ECS Fargate / EC2 / Lambda — TBD)
- CloudFront distribution + S3 origin or ALB, attaching the ACM cert
- IAM roles and least-privilege policies
- GitHub Actions CI/CD pipeline (`terraform plan` on PR, `apply` on merge)
- CloudWatch alarms and log groups
