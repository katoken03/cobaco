# cobaco - VPS Web サーバー管理システム

Ubuntu VPS 上で複数ドメインを運用するための、再現性のあるサーバーセットアップ・管理ツール群。

## 概要

- **Nginx** をリバースプロキシとして使い、複数ドメインのバーチャルホストを管理する
- **ドメインごとに PHP バージョン**（Ubuntu 26.04: 8.5 / 7.4、24.04: 8.3 / 7.4）を切り替えられる（PHP-FPM マルチバージョン）
- **Node.js / Next.js アプリ**は PM2 で管理し、Nginx がリバースプロキシする
- **`domains.yml`** にドメインを宣言的に記述し、スクリプトで自動構成する
- 同じファイル群を別の VPS にコピーして実行すれば、同一構成を再現できる

## ファイル構成

```
cobaco/
├── AGENTS.md             # このファイル。プロジェクト概要と作業指示のインデックス
├── doc.md                # 仕様・パス・構成の説明（仕様変更時は必ず更新）
├── SETUP_USERS.md        # ユーザー・SSH セットアップ手順 (root / deploy)
├── setup.sh              # 初回サーバーセットアップ (Nginx・PHP・PM2・MariaDB 等)
├── add-domain.sh         # ドメイン追加・Nginx 設定生成
├── deploy.sh             # git pull + ビルド + 再起動
├── domains.yml           # ドメイン宣言ファイル (主要設定ファイル)
└── templates/
    ├── nginx-php.conf.tmpl         # PHP（HTTP のみ）
    ├── nginx-php-ssl.conf.tmpl     # PHP（HTTPS・証明書あり）
    ├── nginx-nodejs.conf.tmpl      # Node.js（HTTP のみ）
    └── nginx-nodejs-ssl.conf.tmpl  # Node.js（HTTPS・証明書あり）
```

## 基本的な使い方

```bash
# 0. 初回のみ: SETUP_USERS.md に従い root SSH (鍵のみ) と deploy ユーザーを設定

# 1. root で SSH 接続してセットアップ
bash setup.sh

# 2. domains.yml にドメインを追加してから適用
bash add-domain.sh example.com

# 3. デプロイ (deploy ユーザーで実行)
bash deploy.sh example.com
```

## ユーザー構成

| ユーザー | 役割 |
|---|---|
| `root` | 管理者。SSH は公開鍵のみ（接続元 IP はファイアウォール等で限定）。`setup.sh` / `add-domain.sh` を実行する |
| `deploy` | デプロイ専用。`deploy.sh` のみ実行する。sudo は `systemctl reload` のみ |

## 作業指示ドキュメント

### [doc.md](./doc.md) — 仕様・構成ドキュメント

バーチャルホストの宣言（`domains.yml`）、Nginx 設定、ドキュメントルート、SSL 証明書のパスなどを記載する。**スクリプトや運用仕様を追加・変更したときは、`doc.md` も同じ PR / コミットで更新すること。**

### [SETUP_USERS.md](./SETUP_USERS.md) — ユーザー・SSH セットアップ手順

新規 VPS にこのシステムを導入する際に最初に実行する作業。root の SSH を公開鍵認証のみに設定し、デプロイ用 `deploy` ユーザーと `/var/www/` の権限を整える。**`setup.sh` を実行する前にこの手順を完了させること。**


## コミット時のルール
- コミットメッセージはConventional Commitsを使用すること。メッセージは英語で書くこと。
