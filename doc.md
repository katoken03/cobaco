# cobaco 仕様・構成ドキュメント

運用上のパスやデータの置き場所をまとめる。仕様を変更したら **このファイルも合わせて更新する**（[AGENTS.md](./AGENTS.md) 参照）。

---

## バーチャルホストのデータはどこにあるか

cobaco では **宣言（YAML）・Nginx 設定・サイトの実体** が分かれている。

### 1. 宣言（どのドメインを運用するか）

| 場所 | 内容 |
|------|------|
| **`/root/cobaco_config/domains.yml`** | 本番の正。ドメイン名・`type`・PHP 版・SSL・`basic_auth` など。Git 作業ツリー外のため `git clone` / `pull` の影響を受けない |
| **`domains.yml.sample`** | 雛形（Git 管理）。初回はこれをコピーして編集する |

`add-domain.sh` / `deploy.sh` / `cobaco list` は **`/root/cobaco_config/domains.yml` のみ**を読む。無い場合はエラーで終了する。

本番では root が `/root/cobaco_config/domains.yml` を編集する。`deploy` は読み取りのみ（`deploy.sh` が type 等を参照）。`deploy` が読めるように **`chmod 711 /root`** と **`chmod 644 /root/cobaco_config/domains.yml`** を設定する（`/root` は一覧不可、パスを知っていればファイルに到達可能）。`setup.sh` は `/root/cobaco_config` を `755` で作成する。

既存の `/root/cobaco/domains.yml` から移行する例:

```bash
chmod 711 /root
mkdir -m 755 /root/cobaco_config
mv /root/cobaco/domains.yml /root/cobaco_config/domains.yml
chmod 644 /root/cobaco_config/domains.yml
```

ここを編集して `add-domain.sh` を実行すると、Nginx 設定や Let's Encrypt の取得が行われる。

### PHP バージョン（マルチ FPM）

| Ubuntu | 入手元 | `setup.sh` が入れる版（例） |
|--------|--------|------------------------------|
| **26 以降**（`VERSION_ID` のメジャーが 26 以上） | [packages.sury.org](https://packages.sury.org/php/) | 8.5, 7.3, 7.4, 8.2, 8.3 |
| 25 以下（24.04 など） | **ondrej/php** PPA | 8.3, 7.4 |

Ubuntu 26 以降では sury 全体の優先度を下げ（Pin-Priority 100）、`php-common` と **8.5 / 7.3 / 7.4 / 8.2 / 8.3** の sury 版だけ 500 に pin する。apt の suite 名はその時点のコードネーム（例: resolute）を使う。`domains.yml` の `php_version` は `php${version}-fpm` のソケットにそのまま渡される。

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

パスワードは `/root/cobaco_config/domains.yml` に書く（Git 作業ツリー外）。`basic_auth` を削除して再適用すると htpasswd と Nginx の認証行は外れる。

### 5. SSL 証明書（Let's Encrypt）

| 場所 | 内容 |
|------|------|
| **`/etc/letsencrypt/live/<ドメイン名>/`** | `fullchain.pem` / `privkey.pem`（certbot が管理） |

`domains.yml` で `ssl: true` のとき、`add-domain.sh` が `certbot --nginx` で証明書を取得する。証明書に載せる名前は **`name`（apex）と `ssl_subdomains` に列挙した FQDN のみ**（`www.{domain}` の自動付与はしない）。`ssl_subdomains` の各要素は `*.name` 形式（例: `api.example.com`）とし、同じ vhost（同じドキュメントルート）の別名として Nginx の `server_name` にも反映される。別サイトとして運用するホストは `domains` の別エントリにする。

`www_redirect: true` かつ `ssl: true` のときは、`ssl_subdomains` に **`www.{domain}` を必ず含める**（`server_name` に www を足すため）。

証明書が既にあり、`name` と `ssl_subdomains` の名前がすべて SAN に含まれるドメインは `*-ssl.conf.tmpl` で HTTPS を再生成し、**certbot --nginx は再実行しない**（Basic 認証行が certbot 側で消えるのを防ぐ）。SAN に不足がある場合のみ `certbot --nginx --expand` で追加入力する。YAML から外した名前が証明書に残っていても cobaco は自動削除しない（警告のみ）。証明書の更新は OS の **certbot タイマー**（例: `certbot.timer`）に任せ、cobaco 専用の更新スクリプトはない。

本番の `/root/cobaco_config/domains.yml` を `www_redirect: true` で SSL 利用している場合、`ssl_subdomains` に `www.{domain}` を追記してから `add-domain.sh` を実行する。

---

## 早見表

| 知りたいこと | 見る場所 |
|--------------|----------|
| ドメイン一覧・PHP 版・SSL・Basic 認証 | `/root/cobaco_config/domains.yml` |
| 実際の vhost 設定 | `/etc/nginx/sites-available/<ドメイン>` |
| 公開 Web ファイル（PHP） | `/var/www/<ドメイン>/public/` |
| Basic 認証の htpasswd | `/etc/nginx/htpasswd/<ドメイン>` |
| 証明書 | `/etc/letsencrypt/live/<ドメイン>/` |
