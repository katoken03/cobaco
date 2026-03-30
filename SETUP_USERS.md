# ユーザーセットアップ手順

新規 VPS に `cobaco`（管理者）と `deploy`（デプロイ専用）の2ユーザーを作成し、SSH・sudo を設定する手順。

## 前提条件

- Ubuntu VPS に `root` ユーザーで SSH 接続できる状態
- ローカルの SSH 公開鍵が `/root/.ssh/authorized_keys` に登録済み
- SSH 接続に使う秘密鍵のパスを把握していること

---

## Step 1: cobaco ユーザーの作成

`root` で SSH ログインして実行する。

```bash
# ユーザー作成 (パスワードなし)
adduser --gecos '' --disabled-password cobaco

# sudo フルアクセスを付与 (パスワード不要)
echo 'cobaco ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/cobaco
chmod 440 /etc/sudoers.d/cobaco

# root の SSH 鍵をコピー
mkdir -p /home/cobaco/.ssh
cp /root/.ssh/authorized_keys /home/cobaco/.ssh/
chown -R cobaco:cobaco /home/cobaco/.ssh
chmod 700 /home/cobaco/.ssh
chmod 600 /home/cobaco/.ssh/authorized_keys
```

---

## Step 2: cobaco でのログインを確認してから root ログインを禁止

**重要: cobaco でログインできることを確認してから root を禁止すること。**

```bash
# 別ターミナルで cobaco のログインと sudo を確認
ssh -i <秘密鍵パス> cobaco@<VPSのIPアドレス>
sudo whoami  # → root と表示されれば OK
```

確認できたら root ログインを禁止する。

```bash
# root SSH ログインを禁止
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl reload sshd

# 設定確認
grep '^PermitRootLogin' /etc/ssh/sshd_config
# → PermitRootLogin no
```

---

## Step 3: deploy ユーザーの作成

`cobaco` で SSH ログインし、`sudo` を付けて実行する。

```bash
# ユーザー作成 (パスワードなし)
sudo adduser --gecos '' --disabled-password deploy

# sudoers: systemctl reload のみ許可
sudo tee /etc/sudoers.d/deploy << 'EOF'
deploy ALL=(ALL) NOPASSWD: \
    /bin/systemctl reload php8.3-fpm, \
    /bin/systemctl reload php7.4-fpm, \
    /bin/systemctl reload nginx
EOF
sudo chmod 440 /etc/sudoers.d/deploy

# cobaco の SSH 鍵をコピー
sudo mkdir -p /home/deploy/.ssh
sudo cp ~/.ssh/authorized_keys /home/deploy/.ssh/
sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
sudo chmod 600 /home/deploy/.ssh/authorized_keys

# /var/www/ の所有者を deploy に設定
sudo mkdir -p /var/www
sudo chown deploy:www-data /var/www
sudo chmod 755 /var/www

# deploy を www-data グループに追加 (Nginx が読めるように)
sudo usermod -aG www-data deploy
```

---

## Step 4: 動作確認

```bash
# deploy ユーザーでログインできるか確認
ssh -i <秘密鍵パス> deploy@<VPSのIPアドレス>

# 許可されたコマンドは実行できる
sudo systemctl reload nginx   # → 成功 (nginx 未インストールなら Unit not found で OK)

# 許可外のコマンドは拒否される
sudo apt install curl         # → パスワード要求で拒否されれば OK
```

---

## Step 5: ローカルの SSH config に追加

`~/.ssh/config` に以下を追記する。`<秘密鍵パス>` と `<VPSのIPアドレス>` は環境に合わせて変更する。

```sshconfig
# cobaco VPS - cobaco ユーザー (管理者)
Host xserver_free
  User cobaco
  Port 22
  HostName <VPSのIPアドレス>
  IdentityFile <秘密鍵パス>
  TCPKeepAlive yes
  IdentitiesOnly yes

# cobaco VPS - deploy ユーザー (デプロイ専用)
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
| `cobaco` | フルアクセス (NOPASSWD) | サーバー管理・`setup.sh`・`add-domain.sh` の実行 |
| `deploy` | `systemctl reload` 3コマンドのみ | `deploy.sh` の実行のみ |
| `root` | - | SSH ログイン禁止 |

```
ssh xserver_free         # cobaco → サーバー管理
ssh xserver_free_deploy  # deploy → デプロイのみ
```
