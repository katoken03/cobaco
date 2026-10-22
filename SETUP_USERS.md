# ユーザーセットアップ手順

新規 VPS では **root** でサーバー管理を行い、デプロイ専用に **deploy** ユーザーを 1 つ作成する。SSH は接続元 IP を絞ったうえで、root ログインを**公開鍵認証のみ**許可する。

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

## Step 2: deploy ユーザーの作成

`root` で SSH ログインして実行する。

```bash
# ユーザー作成 (パスワードなし)
adduser --gecos '' --disabled-password deploy

# sudoers: systemctl reload のみ許可
tee /etc/sudoers.d/deploy << 'EOF'
deploy ALL=(ALL) NOPASSWD: \
    /bin/systemctl reload php8.5-fpm, \
    /bin/systemctl reload php8.3-fpm, \
    /bin/systemctl reload php7.4-fpm, \
    /bin/systemctl reload nginx
EOF
chmod 440 /etc/sudoers.d/deploy

# root の SSH 鍵をコピー
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

# /var/www/ の所有者を deploy に設定
mkdir -p /var/www
chown deploy:www-data /var/www
chmod 755 /var/www

# deploy を www-data グループに追加 (Nginx が読めるように)
usermod -aG www-data deploy
```

---

## Step 3: 動作確認

```bash
# root で管理用ログイン
ssh -i <秘密鍵パス> root@<VPSのIPアドレス>

# deploy ユーザーでログイン
ssh -i <秘密鍵パス> deploy@<VPSのIPアドレス>

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

# VPS - deploy (デプロイ専用)
Host xserver_free_deploy
  User deploy
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
| `deploy` | `systemctl reload` のみ | `deploy.sh` の実行のみ |

```
ssh xserver_free         # root → サーバー管理
ssh xserver_free_deploy  # deploy → デプロイのみ
```

---

## セキュリティ上の注意

- root SSH を許可する前提は、**接続元 IP の制限**と**公開鍵のみ**の組み合わせとする。パスワード認証は無効のままにすること。
- `setup.sh` / `add-domain.sh` は root で実行する（`sudo` は不要）。
