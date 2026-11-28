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
| claude-proxy | `proxy.bar504.net` の A レコード（本体は VPS） |
| keiba サイト | S3 + CloudFront（Basic 認証）と homehub からの書き込み専用ユーザー |
| tsu-chiman2 | VPS をオリジンにした CloudFront（許可パス以外を遮断） |
| homehub バックアップ | S3 Glacier Deep Archive と書き込み専用ユーザー |

## 構成図

![構成図](docs/architecture/architecture.png)

- 実線は利用とデータの流れ、点線はデプロイ・監視・通知
- 図は AWS 公式アイコンを同梱した [diagrams](https://diagrams.mingrammer.com/) で生成している。リソースを増減したら
  [`docs/architecture/architecture.py`](docs/architecture/architecture.py) を直して再生成する（手順はスクリプト冒頭）

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
