# cobaco 仕様・構成

詳細は [AGENTS.md](./AGENTS.md) を参照。ここでは運用上のパスとログローテーションを記載する。

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
