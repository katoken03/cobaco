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

### 使っていない PHP-FPM の停止（apply-php-fpm-services.sh）

`domains.yml` で使っているバージョンの FPM だけを動かす。`setup.sh` は全バージョンを enable・start するので、最後にこのスクリプトを呼んで止める。`add-domain.sh` も最後に呼ぶ。`php_version` を変えて使われなくなった旧バージョンも、ここで止める候補になる。

| 判定 | 条件 | 動作 |
|------|------|------|
| 使う | `type: php` のドメインの `php_version`、または `pool.d/` にドメイン用プール（`www.conf` 以外の `*.conf`）がある | 止まっていれば `enable --now`。プールだけ残っているバージョンは警告して止めない |
| 使わない | 上記以外で active か enabled | 一覧を表示し、`不要な PHP-FPM を停止しますか? [y/N]` で y のときだけ `disable --now` |

- **mask しない**。あとでそのバージョンのドメインを追加すると、`add-domain.sh` が `enable --now` で起動する
- `domains.yml` がないとき（初回セットアップ）は何もしない。端末がないときは確認できないので止めない
- `monitor.sh` は enabled な FPM だけを監視するので、止めたバージョンで通知は出ない
- CLI（`cobaco-php` / `composer`）は FPM と別なので、止めても使える

```bash
bash apply-php-fpm-services.sh --dry-run  # 表示のみ
bash apply-php-fpm-services.sh            # 確認してから停止 (root)
bash apply-php-fpm-services.sh --yes      # 確認せずに停止
```

戻すとき: `systemctl enable --now php<ver>-fpm`（または `domains.yml` に書いて `add-domain.sh` を実行）

### Web 実行ユーザーと Unix グループ

サイト別 FPM プールの `user` / `group` は `www-data` のまま（[templates/php-fpm-pool.conf.tmpl](templates/php-fpm-pool.conf.tmpl)）。Nginx も `user www-data` で動く。

| ユーザー | 追加グループ | 目的 |
|----------|--------------|------|
| `cobaco` | `www-data` | PHP が書いたファイルをデプロイユーザーが扱える（[SETUP_USERS.md](SETUP_USERS.md) Step 2） |
| `www-data` | `cobaco` | `/home/cobaco`（通常 `750`）を通過し、`cobaco` 所有でグループに書き込みがあるディレクトリへ PHP がファイルを作成できる |

`www-data` を `cobaco` グループに入れるのは [SETUP_USERS.md](SETUP_USERS.md) Step 2 の `usermod` と、`setup.sh` 再実行時（冪等）。反映には Nginx と該当 `php*-fpm` の再起動が必要で、`setup.sh` が行う。

`www-data` は `cobaco` ユーザーにならない。`cobaco` の sudo 権限や `700` の `.ssh` 等は Web プロセスには渡らない。

## CLI シム（composer / php）

**実行時のカレントディレクトリ**から PHP CLI（`php8.5` / `php7.4` 等）を選ぶ。判定ロジックは [`lib/resolve-composer-php.sh`](lib/resolve-composer-php.sh) に1本化。

| コマンド | 配置 | 主な利用者 |
|----------|------|------------|
| `composer` | `/usr/local/bin/composer` | cobaco / root。phar を選んだ PHP で実行 |
| `cobaco-php` | `/usr/local/bin/cobaco-php` | 明示的にシムを使うとき（root 含む） |
| `php` | `/home/cobaco/bin/php` | **cobaco のみ**。`~/.profile` で `~/bin` を PATH 先頭にしたとき、通常の `php` がシムになる |

システムの `/usr/local/bin/php`（デフォルト PHP）は**上書きしない**。root / cron は従来どおり `php` または `cobaco-php`。

`deploy.sh` の `composer install` も `/usr/local/bin/composer` 経由で同じ解決を使う。

### 導入（root）

```bash
cd /root/cobaco && git pull
bash install-composer.sh
```

Composer phar は `/usr/local/lib/cobaco/composer.phar`。既存の素の `composer` があれば `/usr/local/bin/composer.pre-cobaco` に退避する。`install-composer.sh` は `cobaco-php` と `/home/cobaco/bin/php`、cobaco の `~/.profile`（PATH）も idempotent に配置する。

### PHP バージョンの決め方（優先順）

`composer` / `cobaco-php` / cobaco の `php` で共通。

1. カレントディレクトリから親へ `.php-version`（1 行、例: `8.5` / `7.4`）
2. **最長 prefix 一致** — `/root/cobaco_config/composer-paths.yml` の `paths`（雛形: `composer-paths.yml.sample`）
3. 同上 — `domains.yml` の PHP サイト `/var/www/<name>` と `php_version`
4. どれも無ければ `php`（システムデフォルト）

例: `/home/cobaco/www/siteA` で `php -v` / `composer` → `composer-paths.yml` で `php_version: "8.5"` なら `php8.5` 経由。

`composer-paths.yml` は `domains.yml` と同様 `/root/cobaco_config/` に置き、cobaco が読める権限にする。cobaco で `php -v` を使うときは login shell（または `source ~/.profile`）で PATH が効いていること。

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
| SSH | `ssh.socket` の ListenStream から自動検出（例: 22000） | 許可リスト `/root/cobaco_config/ssh-allow.list` があれば、その IP からのみ許可（下記）。無ければ Anywhere（非 22 のとき `OpenSSH` / 22 ルールを削除） |
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

### SSH 接続元の許可リスト（ssh-allow）

SSH は許可リストに載せた接続元 IP（または CIDR）からだけ受け付ける。リストの管理コマンドは `ssh-allow`（root 専用）。`configure-firewall.sh` が `/usr/local/sbin/ssh-allow` と `/usr/local/lib/cobaco/ssh-allow.sh` に配置する（実体は `bin/ssh-allow` と `lib/ssh-allow.sh`）。

| 項目 | 内容 |
|------|------|
| 許可リスト | `/root/cobaco_config/ssh-allow.list`（Git 外、`600`）。1 行 1 件で「IP または CIDR　メモ」。`#` 以降と空行は無視 |
| UFW | 各 SSH ポートに `allow proto tcp from <IP> to any port <port>`（コメント `SSH allow: <メモ>`）。リストに無い接続元の SSH ルールと Anywhere の SSH ルールは削除する |
| fail2ban | 許可リストの IP を `/etc/fail2ban/jail.d/cobaco-ignoreip.local` の `ignoreip` に入れ、BAN 対象から外す |
| 状態 | **オン**: 許可リストに 1 件以上ある。**オフ**: `ssh-allow off` 済み（リストは `ssh-allow.list.disabled` に退避）。**未設定**: どちらも無い |
| オフ・未設定のとき | SSH は Anywhere で許可（新規 VPS の初回セットアップで締め出さないため）。`configure-firewall.sh` は未設定なら警告、オフなら「意図して公開中」と表示する |
| 最後の 1 件 | オンの間は削除できない。入れ替えるときは先に新しい IP を追加してから古い IP を削除する。絞り込みをやめるなら `ssh-allow off` |

```bash
ssh-allow                          # 番号メニュー（1 一覧 / 2 追加 / 3 削除 / 4 再適用 / 5 オン/オフ / 0 終了）
ssh-allow list                     # 状態、許可リスト、UFW の SSH ルール。ずれがあれば警告
ssh-allow add 203.0.113.5 office   # 追加して即適用（オフ中はリストに追加するだけ）
ssh-allow remove 2                 # 番号または IP で削除して即適用
ssh-allow apply                    # リストを手で編集したあとなどに再適用（冪等）
ssh-allow off                      # 絞り込みをやめて SSH を全体に公開（確認あり。Anywhere を入れてから IP ごとのルールを削除）
ssh-allow on                       # 退避したリストで絞り込みを再開
```

**接続元を絞らないサーバー**（拠点の IP が決まらないクライアント向けなど）では、`setup.sh` の後に `ssh-allow off` を実行しておく。SSH は全体に公開されるが、公開鍵認証のみ・fail2ban の全ポート BAN は有効のまま。未設定のままでも動作は同じだが、`configure-firewall.sh` のたびに警告が出る。

ルールは「許可 IP を追加 → 古いルールを削除」の順に変えるので、作業中の SSH セッションは切れない。今の SSH 接続元を含む IP を削除しようとすると確認を求める。同時実行を防ぐロック（`/run/lock/cobaco-ssh-allow.lock`）は書き換えの間だけ取るので、メニューや確認プロンプトを開いたまま放置しても他の端末の操作は妨げない。ロック中に実行すると、ロックを持っているプロセスの PID・端末・開始時刻を表示して中止する。

**新しい IP から接続したいとき**: ConoHa のコントロールパネルでコンソールを開いて root でログインし、`ssh-allow` を実行して `2`（追加）を選ぶ。入力は IP（数字とドット）とメモだけで済む。

## fail2ban（SSH ブルートフォース対策）

`setup.sh` および単体の `configure-fail2ban.sh` が sshd jail を冪等に設定する。BAN した IP は **全ポートで遮断**する（`banaction = %(banaction_allports)s` → `nftables[type=allports]`）。SSH を 22 以外（例: 22000）で待ち受けていても、ポート指定の漏れで BAN が効かなくなることはない。

| 項目 | 値 |
|------|-----|
| 生成ファイル | `/etc/fail2ban/jail.d/cobaco-sshd.local`（毎回上書き。手で編集しない） |
| ignoreip | `/etc/fail2ban/jail.d/cobaco-ignoreip.local`（`ssh-allow` が SSH 許可リストから生成） |
| backend | `systemd`（journal の `ssh.service` を監視） |
| bantime / findtime / maxretry | 86400 / 600 / 5（`F2B_SSHD_BANTIME` / `F2B_SSHD_FINDTIME` / `F2B_SSHD_MAXRETRY` で変更可） |

`jail.d/*.local` は `/etc/fail2ban/jail.local` より後に読まれるため、手書きの `jail.local` に `[sshd]` があってもこちらが優先される（スクリプトは警告のみ出し、`jail.local` は消さない）。設定検査（`fail2ban-client -t`）に失敗した場合は生成前の状態に戻して終了する。

**適用（root）**:

```bash
cd /root/cobaco && git pull
bash configure-fail2ban.sh
```

**確認**:

```bash
fail2ban-client status sshd
fail2ban-client get sshd actions          # nftables が表示される
nft list table inet f2b-table             # ルールに dport の条件が無いこと
```

## OS の調整（configure-os.sh）

`setup.sh` および単体の `configure-os.sh` が次の 3 点を冪等に適用する。

| 項目 | 内容 | 理由 |
|------|------|------|
| ICMP リダイレクト | `/etc/sysctl.d/60-cobaco.conf` で `net.ipv4.conf.{all,default,*}.send_redirects = 0`（毎回上書き） | ルーターではない（`ip_forward = 0`）ので送る必要がない。実効値は `all` と各インターフェースの OR なので、既存の eth0 にも効くよう glob 行を置く |
| 不要サービス | `ModemManager` / `udisks2` / `upower` を `disable --now` して `mask` | VPS にモデム・取り外せるディスク・バッテリーはない。使わない特権デーモンを減らす。未インストールならスキップ |
| root の PM2 | root の God Daemon が動いていて、アプリが 0 件なら `pm2 kill` | アプリは cobaco の PM2（`pm2-cobaco.service`）で動かす。root にアプリがあれば止めずに警告する |

PM2 はデーモンがないとき、`pm2 --version` などのコマンドを実行しただけで起動する。**root では `pm2` を実行しない**。`setup.sh` は PM2 のバージョンを `package.json` から読む。

**適用（root）**:

```bash
cd /root/cobaco && git pull
bash configure-os.sh
```

**確認**:

```bash
sysctl -a 2>/dev/null | awk '/send_redirects/'   # すべて 0
systemctl is-enabled ModemManager udisks2 upower  # masked
ps -eo user,cmd | awk '/God Daemon/'              # cobaco の 1 本だけ
```

**サービスを戻すとき**: `systemctl unmask <unit> && systemctl enable --now <unit>`

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
