# cobaco 仕様・構成ドキュメント

運用上のパスやデータの置き場所をまとめる。仕様を変更したら **このファイルも合わせて更新する**（[AGENTS.md](./AGENTS.md) 参照）。

---

## バーチャルホストのデータはどこにあるか

cobaco では **宣言（YAML）・Nginx 設定・サイトの実体** が分かれている。

### 1. 宣言（どのドメインを運用するか）

| 場所 | 内容 |
|------|------|
| **`domains.yml`** | ドメイン名・`type`・PHP 版・SSL・`basic_auth` など。cobaco リポジトリ直下（サーバーでは `setup.sh` / `add-domain.sh` と同じディレクトリ、例: `/root/cobaco/domains.yml`） |

`add-domain.sh` / `deploy.sh` は **スクリプト自身のディレクトリ** の `domains.yml` を読む。

ここを編集して `add-domain.sh` を実行すると、Nginx 設定や Let's Encrypt の取得が行われる。

### 2. Nginx のバーチャルホスト設定

| 場所 | 内容 |
|------|------|
| **`/etc/nginx/sites-available/<ドメイン名>`** | 各ドメインの `server` ブロック（`add-domain.sh` がテンプレートから生成） |
| **`/etc/nginx/sites-enabled/<ドメイン名>`** | 上記へのシンボリックリンク（有効化） |
| **`templates/nginx-php.conf.tmpl`** | PHP 用 Nginx テンプレート（HTTP のみ・初回 SSL 取得前） |
| **`templates/nginx-php-ssl.conf.tmpl`** | PHP 用（証明書あり: 80→443 リダイレクト + HTTPS。`basic_auth` は 443 側） |
| **`templates/nginx-nodejs.conf.tmpl`** | Node.js 用（HTTP のみ・初回 SSL 取得前） |
| **`templates/nginx-nodejs-ssl.conf.tmpl`** | Node.js 用（証明書あり） |

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

### 4. ベーシック認証（任意）

`domains.yml` の `basic_auth`（`title` と `users[].id` / `users[].password`）を指定すると、サイト全体に Nginx の Basic 認証がかかる。`add-domain.sh`（`cobaco apply`）が htpasswd と vhost の `auth_basic` を同期する。

| 場所 | 内容 |
|------|------|
| **`/etc/nginx/htpasswd/<ドメイン名>`** | `apache2-utils` の `htpasswd` で生成（bcrypt）。所有者 `root:www-data`、モード `640` |

パスワードは `domains.yml` に書く（`.gitignore` 対象）。`basic_auth` を削除して再適用すると htpasswd と Nginx の認証行は外れる。

### 5. SSL 証明書（Let's Encrypt）

| 場所 | 内容 |
|------|------|
| **`/etc/letsencrypt/live/<ドメイン名>/`** | `fullchain.pem` / `privkey.pem`（certbot が管理） |

`domains.yml` で `ssl: true` のとき、**初回のみ** `add-domain.sh` が `certbot --nginx` で証明書を取得する。証明書が既にあるドメインは `*-ssl.conf.tmpl` で HTTPS を再生成し、**certbot --nginx は再実行しない**（Basic 認証行が certbot 側で消えるのを防ぐ）。証明書の更新は OS の **certbot タイマー**（例: `certbot.timer`）に任せ、cobaco 専用の更新スクリプトはない。

---

## 早見表

| 知りたいこと | 見る場所 |
|--------------|----------|
| ドメイン一覧・PHP 版・SSL・Basic 認証 | `domains.yml` |
| 実際の vhost 設定 | `/etc/nginx/sites-available/<ドメイン>` |
| 公開 Web ファイル（PHP） | `/var/www/<ドメイン>/public/` |
| Basic 認証の htpasswd | `/etc/nginx/htpasswd/<ドメイン>` |
| 証明書 | `/etc/letsencrypt/live/<ドメイン>/` |
