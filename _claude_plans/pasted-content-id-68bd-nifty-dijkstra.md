# fail2ban sshd jail の修正（BAN を全ポート遮断にする）

## Context
本番 VPS（cobaco_ecos_root）では SSH が 22000 番（`ssh.socket` の override）で待ち受けている。一方 fail2ban の sshd jail は `port` が既定の `ssh`（=22）のままなので、nft のルールは `tcp dport 22 ip saddr @addr-set-sshd reject` になっている。BAN された IP（今は 115.160.97.208）でも 22000 には接続できてしまい、BAN が効いていない。

`/etc/fail2ban/jail.local` は 2026-06-05 に手で作られたもので、cobaco リポジトリでは管理していない。`setup.sh` も fail2ban を apt で入れていない。このため別の VPS に同じ構成を再現すると、同じ穴が再発する。

ユーザーの決定:
- BAN は **全ポート遮断**（`banaction_allports`）にする。SSH のポートを変えても設定漏れが起きない。
- recidive jail は今回は入れない。

## 方針
`configure-firewall.sh` と同じ形の冪等なスクリプト `configure-fail2ban.sh` を新しく作る。`setup.sh` から呼び出し、単体でも再適用できるようにする。

### 1. 新規: `configure-fail2ban.sh`（root で実行）
- 冒頭のスタイルは `configure-firewall.sh` に揃える（`set -euo pipefail`、色付きの `info`/`success`/`warn`/`error`、root チェック）。
- `fail2ban-client` が見つからなければ `apt-get install -y -qq fail2ban` を実行する。
- `/etc/fail2ban/jail.d/cobaco-sshd.local` を毎回上書きで生成する。`jail.d/*.local` は `jail.local` より後に読まれるので、手書きの `jail.local` より優先される。
  ```ini
  # cobaco: configure-fail2ban.sh が生成。手で編集しない
  [sshd]
  enabled   = true
  backend   = systemd
  banaction = %(banaction_allports)s
  bantime   = 86400
  findtime  = 600
  maxretry  = 5
  ```
  - `bantime`、`findtime`、`maxretry` は今の値を引き継ぐ。環境変数 `F2B_SSHD_BANTIME`、`F2B_SSHD_FINDTIME`、`F2B_SSHD_MAXRETRY` で上書きできるようにする（`configure-firewall.sh` の `MAIL_TCP_PORTS` と同じやり方）。
  - `banaction_allports` は Debian 既定の `defaults-debian.conf` で `nftables[type=allports]` と定義済みなので、それを使う。
- 既存の `/etc/fail2ban/jail.local` は消さずに残す。中身に `[sshd]` があれば「cobaco-sshd.local が優先される」と `warn` を出すだけにする。
- `fail2ban-client -t` で設定を検査する。失敗したら生成したファイルを元に戻して終了する。
- `systemctl enable --now fail2ban` を実行し、`fail2ban-client reload` で反映する。BAN 中の IP は fail2ban の DB から復元され、新しい allports ルールで塞がれ直す。
- 最後に `fail2ban-client status sshd` を表示する。

### 2. `setup.sh`
- `configure-firewall.sh` を呼んでいるブロック（「ファイアウォール設定」、498 行目付近）の直後に、同じ形式で fail2ban のブロックを追加する:
  ```bash
  info "fail2ban を設定中..."
  bash "${SCRIPT_DIR}/configure-fail2ban.sh"
  ```
- 71 行目付近の基本パッケージのリストに `fail2ban` を追加する。
- 作業ツリーにある未コミットの `setup.sh` の差分（www-data を cobaco グループに入れる変更）には触らない。コミットに含めるのは今回の変更部分だけにする（`git add -p`）。

### 3. ドキュメント
- `DOC.md`: 「ファイアウォール（UFW）」の節の後に「fail2ban」の節を追加する。内容は、生成するファイルのパス、全ポート遮断であること、既定値と環境変数、適用コマンドと確認コマンド。既存の logrotate の表（168 行目の fail2ban の行）はそのままにする。
- `AGENTS.md`: ファイル構成に `configure-fail2ban.sh` の 1 行を追加する。

## 本番への適用手順（実装後、root で実行）
```bash
cd /root/cobaco && git pull
bash configure-fail2ban.sh
```

## 検証
1. ローカル: `bash -n configure-fail2ban.sh`。shellcheck が使えれば `shellcheck configure-fail2ban.sh` も実行する。
2. 本番で適用した後に確認する（読み取りのみ）:
   - `fail2ban-client -d | grep -i "sshd.*action"`: 使われている action が `nftables[type=allports]` になっていること。
   - `nft list table inet f2b-table`: ルールが `ip saddr @addr-set-sshd reject ...` になり、`dport 22` の条件が消えていること。
   - `fail2ban-client status sshd`: 115.160.97.208 が引き続き BAN 中であること（期限は 2026-10-27 16:32 JST）。
   - `fail2ban-client get sshd banaction`
3. 実際に BAN されるかの確認（任意）: 自分の IP 以外の検証用ホストから 22000 に 5 回ログインに失敗し、BAN されて 22000 にも 443 にもつながらなくなることを確かめる。終わったら `fail2ban-client set sshd unbanip <IP>` で解除する。自分の作業用 IP は BAN されないよう、検証は別のホストで行う。
4. 再実行しても差分が出ない（冪等である）ことを確かめる: `configure-fail2ban.sh` をもう一度実行し、エラーにならず同じファイル内容になること。

## コミット
`feat(fail2ban): add configure-fail2ban.sh to ban on all ports for sshd jail`（Conventional Commits、英語、Co-Authored-By を付ける）
