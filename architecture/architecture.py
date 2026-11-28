"""README の構成図を生成する。

AWS 公式アイコン（Architecture Icons）を同梱した `diagrams` ライブラリを使う。
graphviz が必要（macOS: `brew install graphviz`）。

    python3 -m venv /tmp/diagrams && /tmp/diagrams/bin/pip install diagrams
    /tmp/diagrams/bin/python architecture/architecture.py

出力: architecture/architecture.png
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import LambdaFunction
from diagrams.aws.general import TraditionalServer
from diagrams.aws.integration import SimpleNotificationServiceSns
from diagrams.aws.management import Cloudtrail, Cloudwatch, CloudwatchAlarm
from diagrams.aws.network import CloudFront, Route53
from diagrams.aws.security import IAM, CertificateManager, IAMRole
from diagrams.aws.storage import S3, S3Glacier
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.compute import Server
from diagrams.onprem.iac import Terraform
from diagrams.saas.chat import Discord

FONT = "Hiragino Sans"
OUT = Path(__file__).with_name("architecture")

graph_attr = {
    "fontname": FONT,
    "fontsize": "22",
    "pad": "0.4",
    "nodesep": "0.6",
    "ranksep": "0.8",
    "splines": "spline",
    "bgcolor": "white",
}
node_attr = {"fontname": FONT, "fontsize": "13"}
edge_attr = {"fontname": FONT, "fontsize": "11"}
cluster_attr = {"fontname": FONT, "fontsize": "15", "margin": "16"}



def same_rank(cluster, *nodes):
    """クラスタ内のノードを横一列に並べる（dot はクラスタ自体の rank=same を無視するため）。"""
    ids = "; ".join(f'"{n._id}"' for n in nodes)
    cluster.dot.body.append(f"{{rank=same; {ids}}}")


class BackEdge(Edge):
    """段の並びはそのまま、矢印だけ逆に向ける（Edge は dir を >> の向きで上書きするため）。"""

    @property
    def attrs(self):
        return {**super().attrs, "dir": "back"}


# 色覚に頼らないよう、線は色を変えずラベルと線種で区別する
# 実線: 利用・データの流れ / 点線: 監視・通知・デプロイ
ops = {"style": "dashed"}
# 枠を格子状に並べるための見えない線
grid = {"style": "invis"}

with Diagram(
    "bar504-infra（Terraform で管理する AWS アカウント）",
    filename=str(OUT),
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    # AWS の外
    gha = GithubActions("GitHub Actions\nPR で plan・main で apply")
    homehub = Server("homehub\n自宅サーバー")
    vps = TraditionalServer("VPS\ntsu-chiman2 のオリジン\nproxy.bar504.net")
    discord = Discord("Discord")

    with Cluster("AWS", graph_attr=cluster_attr):
        # 1 段目: デプロイ・ドメイン・IAM
        with Cluster("デプロイ（iam.tf）", graph_attr=cluster_attr) as c:
            gha_role = IAMRole("bar504-github-actions\nOIDC で引き受け")
            tf = Terraform("state\nS3 + DynamoDB ロック")
            same_rank(c, gha_role, tf)

        with Cluster("ドメイン（main.tf）", graph_attr=cluster_attr) as c:
            dns = Route53("Route 53\nbar504.net")
            acm = CertificateManager("ACM\n証明書")
            same_rank(c, dns, acm)

        with Cluster("IAM（iam_users.tf）", graph_attr=cluster_attr) as c:
            readonly = IAM("読み取り専用グループ\n個人ユーザー")
            admin_role = IAMRole("bar504-admin\n権限操作はここから")
            same_rank(c, readonly, admin_role)

        # 2 段目: サイトとバックアップ
        with Cluster("keiba サイト（keiba-site.tf）", graph_attr=cluster_attr) as c:
            keiba_pub = IAM("keiba-site-publisher\n書き込み専用")
            keiba_s3 = S3("S3\nサイト")
            keiba_cdn = CloudFront("CloudFront\nBasic 認証\n(Functions + KVS)")
            same_rank(c, keiba_pub, keiba_s3, keiba_cdn)

        with Cluster("tsu-chiman2（tsu-chiman2.tf）", graph_attr=cluster_attr) as c:
            tsu_cdn = CloudFront("CloudFront\n許可パス以外を遮断")

        with Cluster("写真バックアップ（homehub-backup.tf）", graph_attr=cluster_attr) as c:
            backup_user = IAM("homehub-backup\n書き込み専用")
            backup = S3Glacier("S3\nGlacier Deep Archive")
            same_rank(c, backup_user, backup)

        # 3 段目: 監査と監視
        with Cluster("監査（cloudtrail.tf）", graph_attr=cluster_attr) as c:
            trail = Cloudtrail("CloudTrail\n全リージョン")
            trail_s3 = S3("S3\n監査ログ")
            trail_logs = Cloudwatch("CloudWatch Logs\nroot ログイン・\nログイン失敗")
            same_rank(c, trail_s3, trail, trail_logs)

        with Cluster("監視（monitoring.tf、us-east-1 と東京）", graph_attr=cluster_attr) as c:
            alarms = CloudwatchAlarm("CloudWatch アラーム\nCloudFront・DNS・\n証明書・請求額・セキュリティ")
            sns = SimpleNotificationServiceSns("SNS")
            notifier = LambdaFunction("discord-notifier")
            same_rank(c, alarms, sns, notifier)

    # 枠の中の流れ
    gha >> Edge(label="OIDC", **ops) >> gha_role >> Edge(**ops) >> tf
    dns >> acm
    readonly >> Edge(label="スイッチ") >> admin_role
    homehub >> Edge(label="予想 JSON") >> keiba_pub
    keiba_pub >> keiba_s3
    keiba_cdn >> BackEdge(label="OAC") >> keiba_s3
    tsu_cdn >> Edge(label="オリジン") >> vps
    homehub >> Edge(label="写真（週 1）") >> backup_user >> backup
    trail >> trail_s3
    trail >> trail_logs
    trail_logs >> Edge(**ops) >> alarms
    alarms >> Edge(**ops) >> sns >> Edge(**ops) >> notifier >> Edge(label="通知", **ops) >> discord

    # 枠を 3 段に並べる
    gha_role >> Edge(**grid) >> keiba_pub
    keiba_s3 >> Edge(**grid) >> trail
    dns >> Edge(**grid) >> tsu_cdn
    readonly >> Edge(**grid) >> backup_user
    tsu_cdn >> Edge(**grid) >> alarms
