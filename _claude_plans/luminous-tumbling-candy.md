# Nginx catch-all（default_server）の組み込み

## Context

cobaco の Nginx 設定には `default_server` がない。`setup.sh:107` で Ubuntu 付属の default サイトを消しており、テンプレートも `listen 80;` / `listen 443 ssl;` だけなので、Host や SNI が一致しないリクエストは最初に読み込まれたサイト（ecos では shopping）に流れる。
その結果、IP 直打ちや偽の Host でもサイトが表示され、Host ヘッダインジェクション、他人のドメインでの表示、証明書からのドメイン名漏えいにつながる。

一致しないリクエストを catch-all で受け、HTTP は `return 444`、HTTPS は `ssl_reject_handshake on` で拒否する。

ユーザーへの確認結果:
- IP 直打ちなどの正当なアクセスはないので、例外は設けない。
- catch-all へのアクセスは専用ログ `/var/log/nginx/default-catchall-access.log` に残す。

## 変更内容

### 1. `templates/nginx-default.conf`（新規）
catch-all の server ブロック 2 つ。
```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    access_log /var/log/nginx/default-catchall-access.log;
    error_log  /var/log/nginx/default-catchall-error.log;
    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    access_log /var/log/nginx/default-catchall-access.log;
    error_log  /var/log/nginx/default-catchall-error.log;
    ssl_reject_handshake on;
}
```
置き換えるプレースホルダがないので `.tmpl` 拡張子は付けない。

### 2. `configure-nginx-default.sh`（新規・root 用）
`configure-fail2ban.sh` と同じ形にする（冒頭の使い方コメント、`set -euo pipefail`、`info/success/warn/error`、root チェック）。既存サーバーには setup.sh を流し直さず、これ単体で適用できる。

処理:
1. 同じディレクトリの `templates/nginx-default.conf` を `/etc/nginx/sites-available/cobaco-default` に配置し、`/etc/nginx/sites-enabled/cobaco-default` へ `ln -sf` する。
2. `nginx -v` でバージョンを調べる。1.19.4 未満なら `ssl_reject_handshake` が使えないので、443 のブロックを除いて配置し、warn を出す（80 だけ保護）。cobaco の対象は 24.04 以降（nginx 1.24 以上）なので、念のための分岐。
3. `nginx -t` を実行する。失敗したら配置前の状態（ファイルがなかった場合は削除、あった場合は退避したものに戻す）にして終了する。add-domain.sh:456 付近の nginx -t 失敗時の処理と同じ考え方。
4. `systemctl reload nginx` を実行する。
5. 確認用コマンド（`curl -sv http://<IP>/` など）を info で表示する。

冪等にする（何度実行しても同じ状態になる）。

### 3. `setup.sh`
Nginx 設定セクション（`setup.sh:106-121`）で default サイトを無効化した後、`bash "${SCRIPT_DIR}/configure-nginx-default.sh"` を呼ぶ。configure-firewall.sh（`setup.sh:500`）と同じ呼び方にする。既存の `systemctl reload nginx` はそのまま残す。

### 4. HTTP のみのテンプレートに IPv6 を追加
`templates/nginx-php.conf.tmpl:2` と `templates/nginx-nodejs.conf.tmpl:2` の `listen 80;` の次に `listen [::]:80;` を足す（SSL テンプレートの書き方に揃える）。
追加しないと、catch-all を入れた後、HTTP のみのドメインへの IPv6 経由のアクセスが 444 になる。

### 5. ドキュメント
- `DOC.md`: 「ファイアウォール（UFW）」の前あたりに「Nginx の既定サーバー（catch-all）」の節を追加する。内容は目的、配置先、444 と ssl_reject_handshake の意味、ログの場所、既存サーバーへの適用手順、nginx 1.19.4 未満での挙動。
- `AGENTS.md`: ファイル構成に `configure-nginx-default.sh` と `templates/nginx-default.conf` を追加する。

## 既存サーバー（ecos など）への適用手順（DOC.md にも書く）
1. 新しいファイル群をサーバーに反映する。
2. root で `bash configure-nginx-default.sh` を実行する。
3. HTTP のみのドメインがあれば `bash add-domain.sh <domain>` を流し直し、`[::]:80` を反映する。

## 検証
- ローカル: `bash -n configure-nginx-default.sh setup.sh`、`shellcheck configure-nginx-default.sh`（ローカルに nginx はない）。
- サーバー（root、実施はユーザー判断）:
  - `nginx -t` が通り、`nginx -T | rg default_server` で catch-all だけに default_server が付いていること。
  - `curl -sv http://<IP>/` → `Empty reply from server`（444）
  - `curl -sv -H 'Host: evil.example' http://<IP>/` → 同上
  - `curl -skv https://<IP>/` / `openssl s_client -connect <IP>:443 -servername evil.example` → ハンドシェイク失敗で、証明書が返らないこと
  - `curl -sI https://<正規ドメイン>/` → これまでどおり 200 / 30x
  - `tail /var/log/nginx/default-catchall-access.log` に上のテストアクセスが残っていること
  - 証明書の更新に影響がないことを `certbot renew --dry-run` で確認する。

## コミット
Conventional Commits（英語）。例: `feat(nginx): add catch-all default_server rejecting unknown hosts`
