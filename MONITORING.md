# Monitoring

CloudWatch アラームによる bar504 インフラ監視の設計ドキュメント。

## 通知フロー

```
CloudWatch Alarm
  └─ SNS Topic (us-east-1)     ──→ Lambda → Discord
  └─ SNS Topic (ap-northeast-1) ──→ Lambda → Discord
```

CloudFront / Route 53 / ACM / Billing のメトリクスは AWS の仕様上 `us-east-1` に発行されるため、SNS と Lambda もそのリージョンに配置している。CloudTrail 経由のセキュリティイベントは `ap-northeast-1` のログから生成されるため、こちらは東京リージョンの SNS / Lambda を経由する。

## 監視対象とアラーム一覧

### CloudFront (`monitoring.tf`)

対象ディストリビューション: `taskmanager` (E3MX9S634HCDQY) / `tsu_chiman2` (E38ZR5RTOUATOF)  
各ディストリビューションに対して以下 4 アラームが作成される（計 8 個）。

| アラーム名 | メトリクス | 閾値 | 検知内容 |
|-----------|-----------|------|---------|
| `cloudfront-{name}-requests-spike` | `Requests` Sum/5min | **300 req** | DoS・大量アクセス攻撃 |
| `cloudfront-{name}-4xx-error-rate` | `4xxErrorRate` Avg/5min | **25%**（2期間連続） | パススキャン・総当たり |
| `cloudfront-{name}-5xx-error-rate` | `5xxErrorRate` Avg/5min | **5%**（2期間連続） | オリジン障害 |
| `cloudfront-{name}-bandwidth-spike` | `BytesDownloaded` Sum/5min | **500 MB** | DDoS・データ流出 |

> 閾値は `terraform.tfvars` の `cloudfront_request_threshold` / `cloudfront_bandwidth_threshold_bytes` で変更可能。

### Route 53 (`monitoring.tf`)

| アラーム名 | メトリクス | 閾値 | 検知内容 |
|-----------|-----------|------|---------|
| `route53-dns-query-spike` | `DNSQueries` Sum/5min | **1000 req**（2期間連続） | DNS 増幅攻撃・リコネサンス |

### ACM 証明書 (`monitoring.tf`)

| アラーム名 | 対象 | 閾値 | 検知内容 |
|-----------|------|------|---------|
| `acm-cert-expiry-tokyo` | ap-northeast-1 (ALB 用) | **残 30 日** | 証明書期限切れ予告 |
| `acm-cert-expiry-cloudfront` | us-east-1 (CloudFront 用) | **残 30 日** | 証明書期限切れ予告 |

### 請求 (`monitoring.tf`)

| アラーム名 | メトリクス | 閾値 | 検知内容 |
|-----------|-----------|------|---------|
| `billing-estimated-charges` | `EstimatedCharges` Max/日次 | **$10 USD** | 予期しないコスト増（攻撃起因のデータ転送など） |

> **前提**: AWS コンソール → Billing preferences → "Receive CloudWatch Billing Alerts" を有効にすること。

### セキュリティ / CloudTrail (`cloudtrail.tf`)

CloudTrail マルチリージョントレール → CloudWatch Logs → メトリクスフィルター → アラームの構成。カスタム名前空間 `bar504/Security` にメトリクスを発行する。

| アラーム名 | メトリクス | 閾値 | 検知内容 |
|-----------|-----------|------|---------|
| `security-root-account-login` | `RootLogin` Sum/5min | **1 件以上** | root アカウントのコンソールログイン |
| `security-console-login-failures` | `ConsoleLoginFailures` Sum/5min | **5 件以上** | コンソールへのブルートフォース |

## ダッシュボード

`bar504-overview`（us-east-1）に以下のウィジェットを配置。

| ウィジェット | メトリクス | リージョン |
|------------|-----------|----------|
| CloudFront Requests | 両ディストリビューションを重ね表示 | us-east-1 |
| CloudFront Bandwidth | 両ディストリビューションを重ね表示 | us-east-1 |
| CloudFront Error Rates | 4xx / 5xx を各ディストリビューション分 | us-east-1 |
| Route 53 DNS Queries | ホストゾーン単位 | us-east-1 |
| Security Events | RootLogin / ConsoleLoginFailures | ap-northeast-1 |
| Billing Charges | EstimatedCharges (USD) | us-east-1 |

## Terraform 変数

| 変数名 | デフォルト | 説明 |
|--------|-----------|------|
| `cloudfront_distribution_ids` | `{}` | 監視対象ディストリビューション（マップ） |
| `cloudfront_request_threshold` | `300` | リクエスト急増アラームの閾値（req/5min） |
| `cloudfront_bandwidth_threshold_bytes` | `524288000` | 帯域スパイクアラームの閾値（bytes/5min） |
| `route53_dns_query_threshold` | `1000` | DNS クエリ急増アラームの閾値（req/5min、2期間連続で超えた場合に発火） |
| `acm_cert_expiry_days` | `30` | 証明書期限アラームの残日数閾値 |
| `billing_alarm_threshold_usd` | `10` | 請求アラームの閾値（USD） |
| `discord_webhook_url` | — | Discord Webhook URL（sensitive、GitHub Secret に登録） |

## CloudFront ディストリビューションの追加・変更

`terraform.tfvars` の `cloudfront_distribution_ids` マップにエントリを追加して `terraform apply` するだけで、アラームとダッシュボードが自動的に更新される。

```hcl
cloudfront_distribution_ids = {
  taskmanager = "E3MX9S634HCDQY"
  tsu_chiman2 = "E38ZR5RTOUATOF"
  new_service  = "EXXXXXXXXX"      # 追加例
}
```

## GitHub Actions への設定

`discord_webhook_url` は Secrets に登録する（Settings → Secrets and variables → Actions）。

```
Secret name : TF_VAR_DISCORD_WEBHOOK_URL
Value       : https://discord.com/api/webhooks/...
```

`cloudfront_distribution_ids` は Variables に JSON 形式で登録する。

```
Variable name : TF_VAR_cloudfront_distribution_ids
Value         : {"taskmanager":"E3MX9S634HCDQY","tsu_chiman2":"E38ZR5RTOUATOF"}
```
