# SSH の接続元を許可リストの IP に限定し、管理コマンド `ssh-allow` を作る

## Context
本番 VPS の UFW は `22000/tcp ALLOW Anywhere`（v4/v6）になっていて、SSH に世界中から接続できる（AGENTS.md の「接続元 IP は限定」と食い違っている）。これを許可リストに載せたグローバル IP からだけ接続できるようにする。

許可 IP の追加は頻繁に起き、新しい IP からは SSH できないため、作業は ConoHa コントロールパネルのコンソールから行うことになる。コンソールは使いにくい（コピペが効かない、記号の入力が怪しいことがある）ので、短いコマンド＋番号メニューで「一覧・追加・削除」ができるスクリプトを用意する。

現状（読み取りで確認済み）:
- root はパスワードあり（`passwd -S root` → `P`）なので、コンソールから root でログインできる。cobaco はロック中（`L`）。
- サーバーにグローバル IPv6 アドレスはない。
- いまの作業接続元は 115.162.28.152。

ユーザーの決定:
- 初期の許可 IP は **115.162.28.152 のみ**。
- 許可リストの **最後の 1 件は削除できない**（全員締め出しも、意図せぬ全開放も起こさない）。
- 許可リストの IP は fail2ban の **ignoreip にも自動で入れる**。

## 方針
許可リストをファイルで宣言し、`ssh-allow` がそのファイルと UFW（＋fail2ban の ignoreip）を同期する。既存の `bin/composer` ＋ `lib/resolve-composer-php.sh` ＋ `install-composer.sh` と同じ「bin/ のランチャー＋ lib/ の共通処理を /usr/local に install する」形にそろえる。

### 許可リストファイル（Git 外）
`/root/cobaco_config/ssh-allow.list`（`domains.yml` と同じディレクトリ、`600 root:root`）
```
# IP または CIDR  メモ(任意)
115.162.28.152  office
```
1 行 1 件。`#` 以降と空行は無視。

### 1. 新規: `lib/ssh-allow.sh`（共通関数。configure-firewall.sh と bin/ssh-allow の両方が source）
- `ssh_allow_listen_ports`: `configure-firewall.sh` 29〜42 行目にある `ssh.socket` の ListenStream 検出処理をここへ移す（なければ 22）。
- `ssh_allow_read_list`: リストを読んで「アドレス<TAB>メモ」を出力する。
- `ssh_allow_normalize <addr>`: `python3 -c` の `ipaddress.ip_network(strict=False)` で検証・正規化する（`1.2.3.4` → `1.2.3.4`、`1.2.3.0/24` はそのまま、不正なら失敗）。ホスト部が立った CIDR は正規化後の値を使う。
- `ssh_allow_apply`: UFW と fail2ban を許可リストに合わせる（冪等）。
  1. リストが空・ファイルなし → **SSH の既存ルールに触らず** warn して終了（新しい VPS の初回セットアップで締め出されないため。`setup.sh` 実行直後は従来どおり Anywhere で開く）。
  2. 各 SSH ポートと各エントリについて `ufw allow proto tcp from <addr> to any port <port> comment 'SSH allow: <メモ>'` を追加する（UFW は同じルールの二重登録をスキップするので冪等）。
  3. **追加が終わってから**古いルールを消す: `ufw delete allow <port>/tcp`（Anywhere の v4/v6 両方）と `OpenSSH`、および `ufw status` に出ている `<port>/tcp ALLOW IN <addr>` のうちリストにない addr のルール（`ufw delete allow proto tcp from <addr> to any port <port>`）。
  4. fail2ban: `/etc/fail2ban/jail.d/cobaco-ignoreip.local` を生成する。
     ```ini
     # cobaco: ssh-allow が生成。手で編集しない
     [DEFAULT]
     ignoreip = 127.0.0.1/8 ::1 115.162.28.152
     ```
     fail2ban が入っていれば `fail2ban-client -t` で検査してから `fail2ban-client reload`。ignoreip の変更は通常の reload で反映される。

### 2. 新規: `bin/ssh-allow`（root 専用コマンド）
- 呼び出し方:
  - `ssh-allow` → 番号メニュー（`1) 一覧  2) 追加  3) 削除  4) 再適用  0) 終了`）。コンソールで記号を打たずに済むよう、入力は数字・ドット・スラッシュ（CIDR のとき）だけにする。メモは任意入力。
  - `ssh-allow list` / `add <IP> [メモ]` / `remove <番号|IP>` / `apply`（SSH からの通常運用やスクリプト用）
- `list`: 番号付きでリストを表示し、続けて UFW 上の SSH ルール（`ufw status` の SSH ポート行）も表示する。リストと UFW がずれていれば「`ssh-allow apply` で同期できます」と出す。
- `add`: 正規化 → 重複チェック → ファイルに追記 → `ssh_allow_apply`。
- `remove`:
  - 残りが 1 件なら拒否する。
  - 消す IP が今の SSH 接続元（`$SSH_CLIENT` の先頭）を含む場合は、警告して `y` の確認を取る。
  - ファイルから削除 → `ssh_allow_apply`。
- リストファイルの書き換えは一時ファイルに書いてから `mv` で置き換える。
- lib の読み込みは `bin/composer` と同じ方式: リポジトリ内の `../lib/ssh-allow.sh` があればそれを、なければ `/usr/local/lib/cobaco/ssh-allow.sh` を source する。

### 3. `configure-firewall.sh`
- ポート検出を `lib/ssh-allow.sh` の関数に置き換える（動作は同じ）。
- SSH ルール部分（58〜68 行目）は次のようにする:
  - 許可リストがあり空でなければ → `ssh_allow_apply`（Anywhere を追加しない）。
  - リストがなければ → 従来どおり（非 22 なら `<port>/tcp` を Anywhere で許可、22 なら `OpenSSH`）。そのうえで「`ssh-allow add <IP>` で接続元を限定してください」と warn を出す。
- 最後に `install -m 644 lib/ssh-allow.sh /usr/local/lib/cobaco/ssh-allow.sh` と `install -m 755 bin/ssh-allow /usr/local/sbin/ssh-allow` を実行する（setup.sh は configure-firewall.sh を呼ぶので、新しい VPS にも入る）。

### 4. ドキュメント
- `DOC.md` の「ファイアウォール（UFW）」の節: SSH 行の説明を「許可リスト（`/root/cobaco_config/ssh-allow.list`）にある IP からのみ。リストなしなら Anywhere」に更新する。「SSH 接続元の許可リスト（ssh-allow）」の小節を追加する（ファイル形式、コマンド一覧、コンソールでの手順、最後の 1 件は削除不可、fail2ban ignoreip との連動）。fail2ban の節にも `cobaco-ignoreip.local` を 1 行追記する。
- `SETUP_USERS.md`: SSH 設定のあとに「接続元 IP を限定する: `ssh-allow add <IP> <メモ>`」の手順を追加する。
- `AGENTS.md`: ファイル構成に `bin/ssh-allow` と `lib/ssh-allow.sh` を追加し、「接続元 IP は ssh-allow で管理」と 1 行添える。
- 作業ツリーにある既存の未コミット差分（setup.sh の www-data グループ追加、DOC.md / SETUP_USERS.md の関連記述）はコミットに含めない。今回分だけを index に組み立ててコミットする（前回と同じやり方）。

## 本番への適用手順
SSH の作業接続元 115.162.28.152 を先に登録するので、適用中に締め出されることはない（ルールは「追加 → 古いものを削除」の順）。万一に備えて ConoHa のコンソールを開いておいてから実施する。
```bash
cd /root/cobaco && git pull --ff-only
bash configure-firewall.sh            # ssh-allow を /usr/local に配置（リストはまだないので SSH は従来どおり）
ssh-allow add 115.162.28.152 office   # ここで Anywhere が消え、許可 IP のみになる
```

## 検証
1. ローカル: `bash -n` を lib/ssh-allow.sh・bin/ssh-allow・configure-firewall.sh に実行する。
2. 本番:
   - `ufw status numbered`: SSH は `22000/tcp ALLOW IN 115.162.28.152` だけになり、`22000/tcp ALLOW IN Anywhere`（v4/v6）が消えていること。80/443 など他のルールはそのままであること。
   - 新しい SSH セッションを 115.162.28.152 から開けること（今のセッションは閉じずに確認する）。
   - `ssh-allow list` が 1 件とずれなしを表示すること。`ssh-allow remove 1` が「最後の 1 件は削除できません」で拒否されること。
   - `ssh-allow add 192.0.2.10 test` → ufw に追加されること → `ssh-allow remove 192.0.2.10` で消えること（192.0.2.0/24 はドキュメント用アドレスなので無害）。
   - `fail2ban-client get sshd ignoreip` に 115.162.28.152 が入っていること。
   - `ssh-allow apply` を 2 回実行して、ルールが増減しないこと（冪等）。
   - 引数なしの `ssh-allow` のメニューが動くこと（SSH 上で操作）。
3. 外部から: 許可していない回線（例: スマホのテザリング）から `ssh -p 22000` してタイムアウト／拒否されること（任意。ユーザーに依頼）。

## コミット
`feat(firewall): restrict SSH to allowlisted IPs and add ssh-allow command`（Conventional Commits、英語、Co-Authored-By を付ける）
