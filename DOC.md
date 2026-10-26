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

## MariaDB（domains.yml の `mysql`）

ドメインごとに MariaDB のデータベースと専用ユーザーを宣言する。`setup.sh` で入れた MariaDB を前提とし、3306 は UFW で公開しない（localhost / Unix ソケットのみ）。

| 項目 | 説明 |
|------|------|
| 宣言 | `/root/cobaco_config/domains.yml` の各ドメイン直下 `mysql`（配列）。省略または空なら何もしない |
| 適用 | `apply-mysql.sh`（root）。`add-domain.sh` 実行時にも同内容を適用 |
| スクリプト | リポジトリ `apply-mysql.sh`（本番例: `/root/cobaco/apply-mysql.sh`） |

### 宣言フィールド

| キー | 必須 | 説明 |
|------|------|------|
| `database` | はい | データベース名。`domains.yml` 全体で一意 |
| `user` | はい | その DB 専用ユーザー名。全体で一意（他 DB と共有しない） |
| `password` | はい | 平文。ファイルは Git 外（`basic_auth.password` と同様） |
| `charset` | いいえ | 既定 `utf8mb4`。**新規 `CREATE DATABASE` 時のみ** |
| `collation` | いいえ | 既定 `utf8mb4_unicode_ci`。同上 |

`database` / `user` / `charset` / `collation` は `^[A-Za-z][A-Za-z0-9_]*$`、長 1〜64。`password` は空・改行不可。

### 適用ポリシー（宣言に書かない固定値）

- 接続元は `'user'@'localhost'` のみ。アプリの DB ホストは **`localhost`**（`127.0.0.1` は TCP のため対象外）
- 権限は当該データベースに対する `ALL PRIVILEGES` のみ（`database.*`）
- 再実行は冪等（ユーザー作成・パスワード同期・GRANT 再付与）
- **DROP しない**。宣言からエントリを消した・名前を変えた・ドメイン自体を消した場合も、既存 DB / ユーザーは残す
- 既存 DB の文字セットと宣言が食い違う場合は警告のみ（変更しない）

管理接続は root の Unix ソケット（`mysql -u root`）か `/root/.my.cnf`（`chmod 600`）。`mysql_secure_installation` 後は `.my.cnf` が必要なことが多い。root パスワードは `domains.yml` に置かない。`.my.cnf` の `password` に `#` や空白が含まれるときは **ダブルクォートで囲む**（未引用だと `#` 以降がコメントになる）。

アプリの `.env` / `wp-config.php` 等は cobaco では書かない。接続情報は運用側で転記する。

### コマンド（root）

```bash
cd /root/cobaco && git pull
bash apply-mysql.sh example.com
bash apply-mysql.sh --all
bash apply-mysql.sh --dry-run example.com
```

DB だけ変えたときは `apply-mysql.sh` のみでよい（Nginx は触らない）。ドメイン追加・更新時は `add-domain.sh` が内部で `apply-mysql.sh` を呼ぶ。

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
| サーバー監視 | `/etc/logrotate.d/cobaco-monitor` | `install-monitor.sh` が配置 |

対象パス:

- `/root/.pm2/pm2.log`, `/root/.pm2/logs/*.log`
- `/home/cobaco/.pm2/pm2.log`, `/home/cobaco/.pm2/logs/*.log`

ポリシー: **daily**, **rotate 14**, **maxsize 50M**, **compress**, **delaycompress**, **copytruncate**（PM2 がログ FD を開いたままでも切り詰め可能）。Nginx の保持日数に合わせている。

`pm2-logrotate` モジュールは使わない（デーモン起動に依存するため）。

### 運用ログディレクトリ

`setup.sh` は `/var/log/cobaco` を作成し、存在すれば所有者を `cobaco:cobaco` にする。サーバー監視の実行ログは `/var/log/cobaco/monitor.log`（`install-monitor.sh` が `/etc/logrotate.d/cobaco-monitor` を配置）。その他アプリやスクリプトがここに書くログは **個別の logrotate 定義が必要**。PHP プールの `access.log` / `slowlog` を有効にした場合も、出力先に応じて `/etc/logrotate.d` を追加すること。

### 確認コマンド（root）

```bash
systemctl status logrotate.timer
logrotate -d /etc/logrotate.d/cobaco-pm2   # ドライラン
journalctl --disk-usage
```

## ファイアウォール（UFW）

ConoHa VPS 2.0 など **コントロールパネルにファイアウォールが無い** 環境では、OS 上の **UFW** が入口制御の本体とする。`setup.sh` および単体の `configure-firewall.sh` が同じルールを冪等に適用する。

| 種別 | 既定で許可する TCP | 備考 |
|------|-------------------|------|
| Web | 80, 443 | `WEB_TCP_PORTS` で変更可 |
| SSH | `ssh.socket` の ListenStream から自動検出（例: 22000） | 非 22 のとき `OpenSSH` / 22 ルールを削除 |
| メール | 587, 465, 993, 995 | `MAIL_TCP_PORTS` で変更可。**25 は許可しない**（スクリプト内で除外） |
| その他 | 拒否 | 既定 incoming: reject |

メール MTA 未導入でも UFW でポートを開けてよい。MariaDB 等は localhost のみ待ち受けとし、UFW で公開しない。

**適用（root）**:

```bash
cd /root/cobaco && git pull
bash configure-firewall.sh
ufw status verbose
```

メールを載せない VPS では `MAIL_TCP_PORTS= bash configure-firewall.sh` でメール用ルールをスキップできる。

**monitor との整合**: `monitor.yml` の `public_ports.extra_tcp` に UFW で開けた追加ポート（メール等）を書く。省略時は SSH 実ポート + 80 + 443 のみが許可リストになる。

## サーバー監視（異常通知）

サイト単位ではなく **VPS 全体** を対象に、5 分おきの短いチェックでしきい値超過や侵入の兆候だけ HTTPS Webhook へ通知する。常駐エージェントやメトリクス DB は使わない。

| 項目 | パス / 単位 |
|------|-------------|
| 設定（本番） | `/root/cobaco_config/monitor.yml`（`600`。Git 外） |
| 雛形 | リポジトリ `monitor.yml.sample` |
| スクリプト | リポジトリ `monitor.sh`（本番例: `/root/cobaco/monitor.sh`） |
| 状態 | `/var/lib/cobaco/monitor/state`、ジャーナルカーソル `journal.cursor` |
| timer | `cobaco-monitor.timer`（起動 2 分後、以降 5 分間隔） |
| ログ | `/var/log/cobaco/monitor.log` |

`webhook.url` が空の間は `monitor.sh` は何もせず終了する（ジャーナルカーソルも進めない）。

### 監視内容（初期しきい値は sample 参照）

**状態監視** — ALERT 時に通知、復旧で OK 通知。ALERT が続く場合は `cooldowns.alert_repeat_seconds`（既定 6 時間）ごとに再通知。

- **memory**: `MemAvailable / MemTotal` が `memory_available_min_percent` 未満
- **disk**: `/`（および `extra_mounts`）の使用率・ inode 使用率
- **load**: 15 分ロードアベレージが `CPU 数 × load15_multiplier` 超
- **services**: `nginx`、`mariadb`、有効な `php*-fpm` が active でない
- **public_ports**: `0.0.0.0` / `[::]` で待ち受けする TCP のうち、SSH 実ポート・80・443・`public_ports.extra_tcp` 以外

**イベント** — journal カーソルで増分のみ（初回有効化時はカーソルを現在位置に初期化し、過去ログは通知しない）。

- OOM killer（`Out of memory` / `Killed process`）
- SSH 成功ログイン（同一 user + IP は `ssh_success_repeat_seconds` ごと）
- SSH 失敗が `events.ssh_fail_window_seconds` 内に `ssh_fail_min_count` 以上（収束まで再通知しない）
- 予期しない再起動（`btime` 変化。初回は基準記録のみ）

### Webhook

`webhook.format`: `slack`（`{"text":...}`）、`discord`（`{"content":...}`）、`ntfy`（本文 POST + `Title` ヘッダ）。

### 導入・更新（root）

新規 VPS では `setup.sh` が `install-monitor.sh` を呼ぶ。既存サーバー:

```bash
cd /root/cobaco && git pull
bash install-monitor.sh
# /root/cobaco_config/monitor.yml に webhook.url / format を設定
bash monitor.sh --test-notify
bash monitor.sh --dry-run    # 送信せず通知文を標準出力
systemctl status cobaco-monitor.timer
```
