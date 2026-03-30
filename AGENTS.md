# cobaco - VPS Web サーバー管理システム

Ubuntu VPS 上で複数ドメインを運用するための、再現性のあるサーバーセットアップ・管理ツール群。

## 概要

- **Nginx** をリバースプロキシとして使い、複数ドメインのバーチャルホストを管理する
- **ドメインごとに PHP バージョン**（8.3 / 7.4）を切り替えられる（PHP-FPM マルチバージョン）
- **Node.js / Next.js アプリ**は PM2 で管理し、Nginx がリバースプロキシする
- **`domains.yml`** にドメインを宣言的に記述し、スクリプトで自動構成する
- 同じファイル群を別の VPS にコピーして実行すれば、同一構成を再現できる

## ファイル構成

```
cobaco/
├── AGENTS.md             # このファイル。プロジェクト概要と作業指示のインデックス
├── SETUP_USERS.md        # ユーザー作成手順 (cobaco / deploy)
├── setup.sh              # 初回サーバーセットアップ (Nginx・PHP・PM2・MariaDB 等)
├── add-domain.sh         # ドメイン追加・Nginx 設定生成
├── deploy.sh             # git pull + ビルド + 再起動
├── domains.yml           # ドメイン宣言ファイル (主要設定ファイル)
└── templates/
    ├── nginx-php.conf.tmpl     # PHP ドメイン用 Nginx 設定テンプレート
    └── nginx-nodejs.conf.tmpl  # Node.js ドメイン用 Nginx 設定テンプレート
```

## 基本的な使い方

```bash
# 1. 新規 VPS に SSH 接続してセットアップ
sudo bash setup.sh

# 2. domains.yml にドメインを追加してから適用
sudo bash add-domain.sh example.com

# 3. デプロイ (deploy ユーザーで実行)
bash deploy.sh example.com
```

## ユーザー構成

| ユーザー | 役割 |
|---|---|
| `cobaco` | 管理者。`setup.sh` / `add-domain.sh` を実行する |
| `deploy` | デプロイ専用。`deploy.sh` のみ実行する。sudo は最小限 |

## 作業指示ドキュメント

### [SETUP_USERS.md](./SETUP_USERS.md) — ユーザーセットアップ手順

新規 VPS にこのシステムを導入する際に最初に実行する作業。`cobaco`（管理者）と `deploy`（デプロイ専用）の2ユーザーを作成し、SSH・sudo・`/var/www/` の権限を設定する。root SSH ログインの禁止もここで行う。**`setup.sh` を実行する前にこの手順を完了させること。**


## コミット時のルール
- コミットメッセージはConventional Commitsを使用すること。メッセージは英語で書くこと。
