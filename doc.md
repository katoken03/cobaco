# cobaco 仕様・構成ドキュメント

運用上のパスやデータの置き場所をまとめる。仕様を変更したら **このファイルも合わせて更新する**（[AGENTS.md](./AGENTS.md) 参照）。

---

## バーチャルホストのデータはどこにあるか

cobaco では **宣言（YAML）・Nginx 設定・サイトの実体** が分かれている。

### 1. 宣言（どのドメインを運用するか）

| 場所 | 内容 |
|------|------|
| **`domains.yml`** | ドメイン名・`type`・PHP 版・SSL など。cobaco リポジトリ直下（サーバーでは `setup.sh` / `add-domain.sh` と同じディレクトリ、例: `/root/cobaco/domains.yml`） |

`add-domain.sh` / `deploy.sh` は **スクリプト自身のディレクトリ** の `domains.yml` を読む。

ここを編集して `add-domain.sh` を実行すると、Nginx 設定や Let's Encrypt の取得が行われる。

### 2. Nginx のバーチャルホスト設定

| 場所 | 内容 |
|------|------|
| **`/etc/nginx/sites-available/<ドメイン名>`** | 各ドメインの `server` ブロック（`add-domain.sh` がテンプレートから生成） |
| **`/etc/nginx/sites-enabled/<ドメイン名>`** | 上記へのシンボリックリンク（有効化） |
| **`templates/nginx-php.conf.tmpl`** | PHP 用 Nginx テンプレート（リポジトリ内・生成元） |
| **`templates/nginx-nodejs.conf.tmpl`** | Node.js 用 Nginx テンプレート（リポジトリ内・生成元） |

ログ（テンプレート既定）:

- `/var/log/nginx/<ドメイン名>-access.log`
- `/var/log/nginx/<ドメイン名>-error.log`

### 3. サイトのファイル（ドキュメントルート）

`add-domain.sh` が作成するパス:

| 種類 | パス |
|------|------|
| PHP（`type: php`）の公開ディレクトリ | **`/var/www/<ドメイン名>/public`** |
| ドメイン単位の作業ディレクトリ | **`/var/www/<ドメイン名>/`**（`deploy.sh` はここで `git pull` する想定） |
| Node.js（`type: nodejs`） | **`/var/www/<ドメイン名>/`**（`public` サブディレクトリは作らない） |

所有者は `deploy:www-data`（`add-domain.sh` で設定）。

### 4. SSL 証明書（Let's Encrypt）

| 場所 | 内容 |
|------|------|
| **`/etc/letsencrypt/live/<ドメイン名>/`** | `fullchain.pem` / `privkey.pem`（certbot が管理） |

`domains.yml` で `ssl: true` のとき、`add-domain.sh` が `certbot --nginx` で取得する。更新は OS の **certbot タイマー**（例: `certbot.timer`）に任せ、cobaco 専用の更新スクリプトはない。

---

## 早見表

| 知りたいこと | 見る場所 |
|--------------|----------|
| ドメイン一覧・PHP 版・SSL フラグ | `domains.yml` |
| 実際の vhost 設定 | `/etc/nginx/sites-available/<ドメイン>` |
| 公開 Web ファイル（PHP） | `/var/www/<ドメイン>/public/` |
| 証明書 | `/etc/letsencrypt/live/<ドメイン>/` |
