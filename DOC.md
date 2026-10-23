# cobaco 仕様・構成

Ubuntu VPS 上の Web サーバー構成と運用パスの説明。スクリプトや運用仕様を変えたときは本ファイルも同じ変更で更新する。

## ユーザー

| ユーザー | SSH | sudo | 用途 |
|---|---|---|---|
| `root` | 公開鍵のみ（`PermitRootLogin prohibit-password` を推奨） | フル | `setup.sh` / `add-domain.sh` |
| `cobaco` | 公開鍵のみ | `systemctl reload`（nginx / 各 PHP-FPM）のみ | `deploy.sh`、サイト作業 |

初期 SSH 手順は [SETUP_USERS.md](./SETUP_USERS.md) を参照。

## 主要パス

| 用途 | パス |
|---|---|
| ドメイン宣言（本番） | `/root/cobaco_config/domains.yml` |
| ドメイン宣言（雛形） | リポジトリ内 `domains.yml.sample` |
| サイトルート | `/var/www/<domain>/` または `.../public`（`domains.yml` の `webroot` による） |
| Nginx サイト設定 | `/etc/nginx/sites-available/` → `sites-enabled/` |
| Nginx 共通セキュリティヘッダ | `/etc/nginx/conf.d/security.conf` |

`domains.yml` は Git 管理外。`cobaco` が読む場合は `chmod 711 /root` と `chmod 644 /root/cobaco_config/domains.yml`。

## ファイアウォール (ufw)

`setup.sh` は次を行う。

- 受信のデフォルトを拒否し、`Nginx Full`（80 / 443）を許可する。
- **SSH は `ssh.socket` が実際に待ち受ける TCP ポートだけ**を許可する。待ち受けは `systemctl cat ssh.socket` の `ListenStream=` から取得する（drop-in で 22 以外に変更している場合に追随する）。
- 待ち受けが 22 以外のときは、`ufw` の `OpenSSH` プロファイル（常に 22/tcp）と `22/tcp` の許可規則を削除する。22 のままの新規 VPS では従来どおり `ufw allow OpenSSH` を使う。

運用上の SSH ポート変更例（Ubuntu / systemd）:

```bash
mkdir -p /etc/systemd/system/ssh.socket.d
cat > /etc/systemd/system/ssh.socket.d/port.conf << 'EOF'
[Socket]
ListenStream=
ListenStream=0.0.0.0:22000
ListenStream=[::]:22000
EOF
systemctl daemon-reload
systemctl restart ssh.socket
ufw allow 22000/tcp comment 'SSH'
ufw delete allow OpenSSH
```

`setup.sh` を再実行しても、上記の「実ポートのみ許可・22 規則の削除」と整合する。

## ConoHa VPS コンソールと SSH ポート

[ConoHa のコンソール](https://support.conoha.jp/v/console/)は、ブラウザから VNC 相当でゲスト OS のローカル端末（`getty` 等）に接続する機能である。ハイパーバイザー経由のため、**ゲスト OS で SSH が 22 番を待ち受けている必要はない**。

緊急時はコンソールから root（ローカルパスワードまたは recovery 手順）でログインし、22000 番など実際の SSH ポートや `ufw` を確認・修正できる。`ufw` から未使用の 22 番を閉じても、コンソール機能自体は影響を受けない。

コントロールパネルのセキュリティグループ（クラウド側の通信許可）は OS 内の `ufw` とは別レイヤーである。
