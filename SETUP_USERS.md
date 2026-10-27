# ユーザーセットアップ手順

新規 VPS では **root** でサーバー管理を行い、日常作業・デプロイ用に **cobaco** ユーザーを 1 つ作成する。SSH は接続元 IP を絞ったうえで、root ログインを**公開鍵認証のみ**許可する。

ユーザーと責務の一覧は [DOC.md](./DOC.md) を参照。

## 前提条件

- Ubuntu VPS に `root` で SSH 接続できる状態（初期状態、または VPS プロバイダのコンソール）
- ローカルの SSH 公開鍵を `/root/.ssh/authorized_keys` に登録済み
- SSH 接続に使う秘密鍵のパスを把握していること
- ファイアウォールまたはプロバイダ側で、SSH (22) の接続元 IP を限定していること

---

## Step 1: root の SSH を公開鍵のみに設定

`root` で SSH ログインして実行する。**別ターミナルで root ログインが鍵で成功することを確認してから** `sshd` をリロードすること。

```bash
# 公開鍵が未設定なら先に登録する
mkdir -p /root/.ssh
chmod 700 /root/.ssh
# ローカルから: ssh-copy-id -i <秘密鍵> root@<VPSのIPアドレス>
# または authorized_keys を直接編集
chmod 600 /root/.ssh/authorized_keys

# root は公開鍵でのみログイン可（パスワードログイン不可）
grep -q '^PermitRootLogin' /etc/ssh/sshd_config \
    && sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
    || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -q '^PasswordAuthentication' /etc/ssh/sshd_config \
    || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config

sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# 設定確認（リロード前）
sshd -t
grep -E '^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' /etc/ssh/sshd_config
# → PermitRootLogin prohibit-password
# → PasswordAuthentication no
# → PubkeyAuthentication yes

# 別ターミナルで鍵ログインを確認してから実行
systemctl reload sshd
```

---

## Step 2: cobaco ユーザーの作成

`root` で SSH ログインして実行する。**`setup.sh` の前に**完了させること。

```bash
# ユーザー作成 (パスワードなし)
adduser --gecos '' --disabled-password cobaco

# sudoers: systemctl reload のみ許可
tee /etc/sudoers.d/cobaco << 'EOF'
cobaco ALL=(ALL) NOPASSWD: \
    /bin/systemctl reload php8.5-fpm, \
    /bin/systemctl reload php8.3-fpm, \
    /bin/systemctl reload php8.2-fpm, \
    /bin/systemctl reload php7.4-fpm, \
    /bin/systemctl reload php7.3-fpm, \
    /bin/systemctl reload nginx
EOF
chmod 440 /etc/sudoers.d/cobaco

# root の SSH 鍵をコピー
mkdir -p /home/cobaco/.ssh
cp /root/.ssh/authorized_keys /home/cobaco/.ssh/
chown -R cobaco:cobaco /home/cobaco/.ssh
chmod 700 /home/cobaco/.ssh
chmod 600 /home/cobaco/.ssh/authorized_keys

# /var/www/ の所有者を cobaco に設定
mkdir -p /var/www
chown cobaco:www-data /var/www
chmod 755 /var/www

# cobaco を www-data グループに追加 (PHP が書いたファイルを cobaco が読めるように)
usermod -aG www-data cobaco

# www-data を cobaco グループに追加 (/home/cobaco 配下や cobaco 所有の writable へ PHP が書ける)
usermod -aG cobaco www-data

# Nginx / PHP-FPM の再起動は setup.sh が行う (この時点ではまだサービス未導入のことが多い)

# cobaco 運用ログ (setup.sh でも作成するが、先に作っておいてもよい)
mkdir -p /var/log/cobaco
chown cobaco:cobaco /var/log/cobaco
chmod 755 /var/log/cobaco
```

---

## Step 3: 動作確認

```bash
# root で管理用ログイン
ssh -i <秘密鍵パス> root@<VPSのIPアドレス>

# cobaco ユーザーでログイン
ssh -i <秘密鍵パス> cobaco@<VPSのIPアドレス>

# 許可されたコマンドは実行できる
sudo systemctl reload nginx   # → 成功 (nginx 未インストールなら Unit not found で OK)

# 許可外のコマンドは拒否される
sudo apt install curl         # → パスワード要求で拒否されれば OK
```

---

## Step 4: ローカルの SSH config に追加

`~/.ssh/config` に以下を追記する。`<秘密鍵パス>` と `<VPSのIPアドレス>` は環境に合わせて変更する。

```sshconfig
# VPS - root (管理者)
Host xserver_free
  User root
  Port 22
  HostName <VPSのIPアドレス>
  IdentityFile <秘密鍵パス>
  TCPKeepAlive yes
  IdentitiesOnly yes

# VPS - cobaco (デプロイ・日常作業)
Host xserver_free_cobaco
  User cobaco
  Port 22
  HostName <VPSのIPアドレス>
  IdentityFile <秘密鍵パス>
  TCPKeepAlive yes
  IdentitiesOnly yes
```

---

## ユーザーの役割まとめ

| ユーザー | sudo 権限 | 用途 |
|---|---|---|
| `root` | フル | サーバー管理・`setup.sh`・`add-domain.sh` の実行 |
| `cobaco` | `systemctl reload` のみ | `deploy.sh`、サイトファイル編集、PM2 |

```
ssh xserver_free         # root → サーバー管理
ssh xserver_free_cobaco  # cobaco → デプロイ・日常作業
```

---

## 既存 VPS: deploy から cobaco へ移行

以前 `deploy` ユーザーを使っていたサーバー向け。root で実行する。

```bash
# cobaco が無ければ Step 2 と同様に作成 (deploy は残したままでも可)

# ファイル所有者
chown -R cobaco:www-data /var/www

# sudoers
rm -f /etc/sudoers.d/deploy
# /etc/sudoers.d/cobaco は Step 2 の内容で作成済みであること

# PM2 を cobaco に移す (Node サイトがある場合)
sudo -u cobaco bash -lc 'export NVM_DIR=/opt/nvm; . "$NVM_DIR/nvm.sh"; pm2 save' || true
sudo -u root bash -lc 'export NVM_DIR=/opt/nvm; . "$NVM_DIR/nvm.sh"; pm2 unstartup systemd' || true
sudo -u cobaco bash -lc 'export NVM_DIR=/opt/nvm; . "$NVM_DIR/nvm.sh"; pm2 startup systemd -u cobaco --hp /home/cobaco' | tail -1 | bash

# deploy の SSH 鍵・ホームを不要なら削除
# deluser --remove-home deploy
```

移行後、`deploy` で動いていた cron や CI の SSH ユーザーを `cobaco` に変更する。

---

## セキュリティ上の注意

- root SSH を許可する前提は、**接続元 IP の制限**と**公開鍵のみ**の組み合わせとする。パスワード認証は無効のままにすること。
- `setup.sh` / `add-domain.sh` は root で実行する（`sudo` は不要）。
