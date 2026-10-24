# cobaco 仕様・構成

詳細は [AGENTS.md](./AGENTS.md) を参照。ここでは運用上のパスとログローテーションを記載する。

## PHP 設定

Web (PHP-FPM) 向けの PHP 設定は次の3層に分ける。CLI (`php`, `composer`, `artisan`) にはサイト設定は効かず、`/etc/php/<ver>/cli/php.ini` を使う。

| 層 | 正本 / 配置 | 責任 |
|----|-------------|------|
| バージョン共通 | リポジトリ `templates/php/<ver>/99-cobaco.ini` → サーバー `/etc/php/<ver>/fpm/conf.d/99-cobaco.ini` | その PHP バージョンの全 FPM プール共通。`apply-php-fpm-ini.sh` または `setup.sh` がコピーする |
| 宣言 | `/root/cobaco_config/domains.yml` の `php_settings` | サイトごとに変えたい ini の差分 |
| サイト別 FPM プール | `/var/www/<domain>/conf/php-fpm.conf` | `add-domain.sh` が `domains.yml` から毎回生成。所有者 `root:root`。ドキュメントルートは `public/` のため Web からは読めない |

PHP-FPM は `/etc/php/<ver>/fpm/php-fpm.conf` の `include=/etc/php/<ver>/fpm/pool.d/*.conf` でプールを読む。サイトの実体は `/var/www/<domain>/conf/php-fpm.conf` に置き、FPM が読めるよう `/etc/php/<ver>/fpm/pool.d/<domain>.conf` からシンボリックリンクする。

Nginx の `fastcgi_pass` はサイト専用ソケット `/run/php/php<ver>-fpm-<domain>.sock` を指す。

パッケージの `/etc/php/<ver>/fpm/php.ini` と `/etc/php/<ver>/cli/php.ini` は編集しない。ドメイン用プールを置いたバージョンでは、既定の `/etc/php/<ver>/fpm/pool.d/www.conf` を `www.conf.disabled` に退避する（`add-domain.sh` および `setup.sh` 再実行時）。

### domains.yml の `php_settings`（任意）

`php_settings` を省略したキーは、バージョン共通 ini（実質パッケージ php.ini + `99-cobaco.ini`）のまま。`php_settings` 自体を省略しても、サイト用プールと専用ソケットは作成される。

| キー | FPM への出力 |
|------|----------------|
| `memory_limit`, `upload_max_filesize`, `post_max_size`, `max_execution_time`, `max_input_time`, `max_input_vars`, `error_reporting`, `date.timezone` | `php_admin_value[...]` |
| `display_errors`, `display_startup_errors` | `php_admin_flag[...]` (`On` / `Off`) |

`php_version` を変更したときは、古いバージョンの `pool.d/<domain>.conf` リンクを外し、新バージョンに張り直して両方の FPM を reload する。

### バージョン共通デフォルトの追加・変更

全サイト・全 FPM プールに必ず効かせたい ini（セキュリティ基線など）は、`domains.yml` ではなく次の **5 ファイルすべて**に同じ内容を書く。

- `templates/php/7.3/99-cobaco.ini`
- `templates/php/7.4/99-cobaco.ini`
- `templates/php/8.2/99-cobaco.ini`
- `templates/php/8.3/99-cobaco.ini`
- `templates/php/8.5/99-cobaco.ini`

特定の PHP バージョンだけ値を変える必要があるときだけ、該当ファイルだけ差分を書く。コメントに日付と理由（CVE 番号など）を残す。

**本番への反映**（ini だけ変えたとき。`add-domain.sh` は不要）:

```bash
cd /root/cobaco && git pull
bash apply-php-fpm-ini.sh
```

初回 VPS や PHP パッケージ追加直後は `bash setup.sh` でもよい（ini 配置に加え `www.conf` 退避を行う）。

**確認**（root）:

```bash
ls -la /etc/php/8.5/fpm/conf.d/99-cobaco.ini
php-fpm8.5 -i 2>/dev/null | rg 'session.upload_progress.enabled'
```

## ログローテーション

`setup.sh` 実行後、Ubuntu の `logrotate.timer`（通常は日次）で `/etc/logrotate.d/` の定義が適用される。

### パッケージ標準（setup.sh では追加しない）

| 対象 | 設定ファイル | 概要 |
|------|-------------|------|
| Nginx | `/etc/logrotate.d/nginx` | `/var/log/nginx/*.log` — daily, rotate 14, compress。postrotate で `nginx rotate` |
| PHP-FPM | `/etc/logrotate.d/php*-fpm` | `/var/log/phpX.Y-fpm.log` — weekly, rotate 12。各バージョンの `php*-fpm-reopenlogs` |
| rsyslog | `/etc/logrotate.d/rsyslog` | `syslog`, `auth.log`, `kern.log` 等 — weekly, rotate 4 |
| UFW | `/etc/logrotate.d/ufw` | `/var/log/ufw.log` |
| MariaDB | `/etc/logrotate.d/mariadb` | `/var/log/mysql/*.log`, `/var/lib/mariadb/*.log` — monthly, rotate 6, maxsize 500M |
| certbot | `/etc/logrotate.d/certbot` | `/var/log/letsencrypt/*.log` |
| fail2ban | `/etc/logrotate.d/fail2ban` | `/var/log/fail2ban.log` |
| apt / dpkg / unattended-upgrades 等 | 各 `/etc/logrotate.d/*` | ディストリビューション既定 |

MariaDB のエラーは多くの構成で **syslog / journald** に出る（`log_error` 未指定時）。バイナリログは `binlog_expire_logs_seconds`（例: 10 日）で期限切れ。`ib_logfile*` や `aria_log*` はデータファイルであり logrotate の対象外。

**journald**: `/etc/systemd/journald.conf` の既定（ディスク使用率上限など）。**sysstat**: `sysstat-rotate.timer` と `/etc/sysstat/sysstat` の `HISTORY`。**dmesg**: 起動時 `dmesg.service` が `savelog -c 5` で `/var/log/dmesg` を世代管理。

### cobaco が追加する定義

| 対象 | 設定ファイル | 概要 |
|------|-------------|------|
| PM2 | `/etc/logrotate.d/cobaco-pm2` | `setup.sh` が配置 |

対象パス:

- `/root/.pm2/pm2.log`, `/root/.pm2/logs/*.log`
- `/home/cobaco/.pm2/pm2.log`, `/home/cobaco/.pm2/logs/*.log`

ポリシー: **daily**, **rotate 14**, **maxsize 50M**, **compress**, **delaycompress**, **copytruncate**（PM2 がログ FD を開いたままでも切り詰め可能）。Nginx の保持日数に合わせている。

`pm2-logrotate` モジュールは使わない（デーモン起動に依存するため）。

### 運用ログディレクトリ

`setup.sh` は `/var/log/cobaco` を作成し、存在すれば所有者を `cobaco:cobaco` にする。アプリやスクリプトがここに書くログは **個別の logrotate 定義が必要**（現状 cobaco リポジトリでは未提供）。PHP プールの `access.log` / `slowlog` を有効にした場合も、出力先に応じて `/etc/logrotate.d` を追加すること。

### 確認コマンド（root）

```bash
systemctl status logrotate.timer
logrotate -d /etc/logrotate.d/cobaco-pm2   # ドライラン
journalctl --disk-usage
```
