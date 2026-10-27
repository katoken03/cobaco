# cobaco - VPS Web サーバー管理システム

Ubuntu VPS 上で複数ドメインを運用するための、再現性のあるサーバーセットアップ・管理ツール群。

## Tools

Use fd, not find.
Use rg, not grep.


## 概要

- **Nginx** をリバースプロキシとして使い、複数ドメインのバーチャルホストを管理する
- **ドメインごとに PHP バージョン**（Ubuntu 26 以降: 8.5 / 8.3 / 8.2 / 7.4 / 7.3、24.04 など: 8.3 / 7.4）を切り替えられる（PHP-FPM マルチバージョン）
- **Node.js / Next.js アプリ**は PM2 で管理し、Nginx がリバースプロキシする
- **`domains.yml`** にドメインを宣言的に記述し、スクリプトで自動構成する
- 同じファイル群を別の VPS にコピーして実行すれば、同一構成を再現できる

## ファイル構成

```
cobaco/
├── AGENTS.md             # このファイル。プロジェクト概要と作業指示のインデックス
├── DOC.md                # 仕様・パス・構成の説明（仕様変更時は必ず更新）
├── SETUP_USERS.md        # ユーザー・SSH セットアップ手順 (root / cobaco)
├── setup.sh              # 初回サーバーセットアップ (Nginx・PHP・PM2・MariaDB 等)
├── configure-firewall.sh # UFW: Web / SSH / メール(任意) のみ許可
├── configure-fail2ban.sh # fail2ban sshd jail (BAN は全ポート遮断)
├── apply-php-fpm-ini.sh  # バージョン共通 FPM ini の配置と FPM reload
├── apply-mysql.sh        # domains.yml の mysql 宣言を MariaDB に適用
├── install-composer.sh   # Composer phar + ディレクトリ連動ランチャー (root)
├── add-domain.sh         # ドメイン追加・Nginx 設定生成
├── composer-paths.yml.sample  # Composer 用 PHP バージョンのパス対応（Git 外本番用）
├── bin/composer          # ランチャー本体 → install-composer.sh が /usr/local/bin に配置
├── bin/cobaco-php        # PHP CLI シム → /usr/local/bin/cobaco-php と cobaco ~/bin/php
├── lib/resolve-composer-php.sh
├── deploy.sh             # git pull + ビルド + 再起動
├── monitor.sh            # サーバー異常検知と Webhook 通知
├── install-monitor.sh    # monitor の systemd timer / logrotate 配置
├── domains.yml.sample    # ドメイン宣言の雛形
├── monitor.yml.sample    # サーバー監視設定の雛形
└── templates/
    ├── nginx-php.conf.tmpl         # PHP（HTTP のみ）
    ├── nginx-php-ssl.conf.tmpl     # PHP（HTTPS・証明書あり）
    ├── nginx-nodejs.conf.tmpl      # Node.js（HTTP のみ）
    ├── nginx-nodejs-ssl.conf.tmpl  # Node.js（HTTPS・証明書あり）
    ├── php-fpm-pool.conf.tmpl      # サイト別 PHP-FPM プール
    └── php/
        └── <ver>/99-cobaco.ini     # バージョン共通 FPM ini (7.3 / 7.4 / 8.2 / 8.3 / 8.5)
```

## 基本的な使い方

```bash
# 0. 初回のみ: SETUP_USERS.md に従い root SSH (鍵のみ) と cobaco ユーザーを設定

# 1. root で SSH 接続してセットアップ
bash setup.sh

# 2. 本番: /root/cobaco_config/domains.yml にドメインを追加してから適用
#    (domains.yml.sample をコピー。cobaco が読めるよう chmod 711 /root && chmod 644 ファイル)
bash add-domain.sh example.com
# DB だけ更新するとき: bash apply-mysql.sh example.com  (root)

# 3. デプロイ (cobaco ユーザーで実行)
bash deploy.sh example.com
```

## ユーザー構成

| ユーザー | 役割 |
|---|---|
| `root` | 管理者。SSH は公開鍵のみ（接続元 IP はファイアウォール等で限定）。`setup.sh` / `add-domain.sh` を実行する |
| `cobaco` | 日常作業・デプロイ。`deploy.sh` を実行する。sudo は `systemctl reload` のみ |

詳細は [DOC.md](./DOC.md) のユーザー表を参照。

## 作業指示ドキュメント

### [DOC.md](./DOC.md) — 仕様・構成ドキュメント

バーチャルホストの宣言（`domains.yml`）、Nginx 設定、ドキュメントルート、SSL 証明書のパスなどを記載する。**スクリプトや運用仕様を追加・変更したときは、`DOC.md` も同じ PR / コミットで更新すること。**

### [SETUP_USERS.md](./SETUP_USERS.md) — ユーザー・SSH セットアップ手順

新規 VPS にこのシステムを導入する際に最初に実行する作業。root の SSH を公開鍵認証のみに設定し、`cobaco` ユーザーと `/var/www/` の権限を整える。**`setup.sh` を実行する前にこの手順を完了させること。**


## コミット時のルール
- コミットメッセージはConventional Commitsを使用すること。メッセージは英語で書くこと。
