# bar504-infra

Bar504 組織の AWS インフラを Terraform で管理するリポジトリ。
Terraform state は S3（`bar504-terraform-state`）+ DynamoDB ロックで管理。

## 管理リソース

| リソース | 説明 |
|---|---|
| GitHub Actions OIDC ロール | `bar504-github-actions`（Bar504/*・ShoIwase/* を信頼） |
| Route 53 / ACM | bar504.net のドメイン管理・証明書 |
| CloudTrail | 全 API 操作の監査ログ |
| CloudWatch Alarms | CloudFront リクエスト数・帯域・請求額アラーム → Discord 通知 |
| claude-proxy | Anthropic API プロキシ Lambda |

## デプロイ

main ブランチへの push で GitHub Actions が `terraform apply` を自動実行。

```bash
# ローカル確認のみ（apply は CI 経由）
terraform init
terraform plan
```

## 注意

- `terraform apply` は直接実行せず、main ブランチへの PR → マージで行う
- Secrets（Discord Webhook 等）は GitHub Actions Variables/Secrets で管理
