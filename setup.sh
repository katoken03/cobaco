#!/usr/bin/env bash
# setup.sh - VPS 初回セットアップスクリプト
# 使い方: sudo bash setup.sh
# 再実行しても安全 (冪等性を考慮)

set -euo pipefail

# ─────────────────────────────────────────────
# 色付き出力ヘルパー
# ─────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─────────────────────────────────────────────
# root 確認
# ─────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "このスクリプトは root (sudo) で実行してください。"
    exit 1
fi

# スクリプト自身のディレクトリを記録 (templates/ 等へのパスに使用)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────
# Ubuntu バージョン確認・警告
# ─────────────────────────────────────────────
UBUNTU_CODENAME="$(lsb_release -sc 2>/dev/null || echo unknown)"
UBUNTU_VERSION="$(lsb_release -sr 2>/dev/null || echo unknown)"

info "Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}) を検出しました。"

if [[ "$UBUNTU_CODENAME" == "plucky" ]]; then
    warn "Ubuntu 25.04 (Plucky) は 2026-01 に EOL を迎えており、サポートが終了しています。"
    warn "長期運用には Ubuntu 24.04 LTS (Noble) への移行を強く推奨します。"
    echo ""
    read -rp "続行しますか？ [y/N]: " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        info "セットアップを中断しました。"
        exit 0
    fi
fi

# ─────────────────────────────────────────────
# パッケージリストの更新
# ─────────────────────────────────────────────
info "パッケージリストを更新中..."
apt-get update -qq
apt-get upgrade -y -qq
success "パッケージ更新完了"

# ─────────────────────────────────────────────
# 基本依存パッケージ
# ─────────────────────────────────────────────
info "基本パッケージをインストール中..."
apt-get install -y -qq \
    curl \
    wget \
    git \
    unzip \
    software-properties-common \
    ufw \
    nginx \
    mariadb-server \
    certbot \
    python3-certbot-nginx
success "基本パッケージのインストール完了"

# ─────────────────────────────────────────────
# yq のインストール (YAML パーサー)
# ─────────────────────────────────────────────
if ! command -v yq &>/dev/null; then
    info "yq をインストール中..."
    YQ_VERSION="v4.44.1"
    YQ_BINARY="yq_linux_amd64"
    wget -qO /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
    chmod +x /usr/local/bin/yq
    success "yq ${YQ_VERSION} のインストール完了"
else
    success "yq は既にインストール済み: $(yq --version)"
fi

# ─────────────────────────────────────────────
# Nginx の設定
# ─────────────────────────────────────────────
info "Nginx の設定を調整中..."

# デフォルトサイトを無効化
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm /etc/nginx/sites-enabled/default
    info "デフォルトサイトを無効化しました。"
fi

# セキュリティヘッダー設定 (server_tokens は nginx.conf に既に定義されているため除外)
cat > /etc/nginx/conf.d/security.conf << 'EOF'
add_header X-Frame-Options SAMEORIGIN;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
EOF

systemctl enable nginx
systemctl reload nginx
success "Nginx の設定完了"

# ─────────────────────────────────────────────
# PHP マルチバージョン (ondrej/php PPA)
# ─────────────────────────────────────────────
info "ondrej/php PPA を追加中..."
add-apt-repository -y ppa:ondrej/php

# ondrej/php PPA は LTS のみサポート。非 LTS (plucky 等) の場合は noble に書き換える
SOURCES_FILE=$(find /etc/apt/sources.list.d/ -name "*ondrej*php*" | head -1)
if [[ -n "$SOURCES_FILE" ]] && grep -q "Suites: ${UBUNTU_CODENAME}" "$SOURCES_FILE"; then
    if ! curl -sf "https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/${UBUNTU_CODENAME}/Release" -o /dev/null; then
        warn "ondrej/php PPA は ${UBUNTU_CODENAME} 未対応のため、noble (24.04 LTS) のパッケージを使用します。"
        sed -i "s/Suites: ${UBUNTU_CODENAME}/Suites: noble/" "$SOURCES_FILE"
    fi
fi

apt-get update -qq
success "PPA の追加完了"

# PHP 8.3 のインストール
info "PHP 8.3 をインストール中..."
apt-get install -y -qq \
    php8.3-fpm \
    php8.3-mysql \
    php8.3-curl \
    php8.3-mbstring \
    php8.3-xml \
    php8.3-zip \
    php8.3-intl \
    php8.3-gd \
    php8.3-bcmath \
    php8.3-opcache
systemctl enable php8.3-fpm
systemctl start php8.3-fpm
success "PHP 8.3 のインストール完了"

# PHP 7.4 のインストール (PPA サポート確認付き)
info "PHP 7.4 の利用可否を確認中..."
if apt-cache show php7.4-fpm &>/dev/null; then
    info "PHP 7.4 をインストール中..."
    apt-get install -y -qq \
        php7.4-fpm \
        php7.4-mysql \
        php7.4-curl \
        php7.4-mbstring \
        php7.4-xml \
        php7.4-zip \
        php7.4-gd \
        php7.4-bcmath \
        php7.4-opcache
    systemctl enable php7.4-fpm
    systemctl start php7.4-fpm
    success "PHP 7.4 のインストール完了"
else
    warn "PHP 7.4 はこの Ubuntu バージョン (${UBUNTU_VERSION}) の PPA では利用できません。"
    warn "PHP 7.4 が必要な場合、以下の選択肢を検討してください:"
    warn "  1. Docker コンテナとして PHP 7.4 を隔離運用する (php74-docker/ ディレクトリを参照)"
    warn "  2. Ubuntu 22.04 LTS への移行"
    warn "PHP 7.4 のセットアップをスキップしてセットアップを続行します。"
fi

# ─────────────────────────────────────────────
# Node.js + PM2 (nvm 経由でシステムワイドインストール)
# ─────────────────────────────────────────────
NVM_DIR="/opt/nvm"

if [[ ! -d "$NVM_DIR" ]]; then
    info "nvm をシステムワイドにインストール中 (${NVM_DIR})..."
    git clone --depth=1 https://github.com/nvm-sh/nvm.git "$NVM_DIR"
    success "nvm のクローン完了"
else
    info "nvm は既にインストール済みです (${NVM_DIR})"
fi

# /etc/profile.d に nvm のパスを設定 (全ユーザー・sudo でも使えるように)
cat > /etc/profile.d/nvm.sh << EOF
export NVM_DIR="${NVM_DIR}"
[ -s "\${NVM_DIR}/nvm.sh" ] && . "\${NVM_DIR}/nvm.sh"
[ -s "\${NVM_DIR}/bash_completion" ] && . "\${NVM_DIR}/bash_completion"
EOF
chmod +x /etc/profile.d/nvm.sh

# nvm を現在のシェルで有効化して Node.js LTS をインストール
export NVM_DIR="${NVM_DIR}"
# shellcheck source=/dev/null
source "${NVM_DIR}/nvm.sh"

info "Node.js LTS をインストール中..."
nvm install --lts
nvm alias default lts/*
NODE_PATH="$(nvm which default)"
success "Node.js $(node --version) のインストール完了"

# PM2 のインストール
if ! npm list -g pm2 &>/dev/null; then
    info "PM2 をグローバルインストール中..."
    npm install -g pm2
    success "PM2 $(pm2 --version) のインストール完了"
else
    success "PM2 は既にインストール済み"
fi

# PM2 systemd スタートアップ設定
info "PM2 systemd スタートアップを設定中..."
pm2 startup systemd -u root --hp /root | tail -1 | bash || true
success "PM2 スタートアップ設定完了"

# ─────────────────────────────────────────────
# MariaDB セキュリティ設定
# ─────────────────────────────────────────────
info "MariaDB を設定中..."
systemctl enable mariadb
systemctl start mariadb

# root パスワードが未設定の場合のみ設定
if mysql -u root -e "SELECT 1;" &>/dev/null; then
    info "MariaDB root パスワードを設定してください:"
    mysql_secure_installation
    success "MariaDB のセキュリティ設定完了"
else
    warn "MariaDB root には既にパスワードが設定されています。スキップします。"
fi

# ─────────────────────────────────────────────
# ファイアウォール設定
# ─────────────────────────────────────────────
info "ファイアウォール (ufw) を設定中..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable
success "ファイアウォール設定完了"

# ─────────────────────────────────────────────
# 完了メッセージ
# ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  セットアップが完了しました!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "次のステップ:"
echo "  1. domains.yml にドメインを追加する"
echo "  2. sudo bash add-domain.sh <ドメイン名> を実行する"
echo ""
info "インストール済みバージョン:"
nginx -v 2>&1 || true
php8.3 --version | head -1 || true
php7.4 --version 2>/dev/null | head -1 || warn "PHP 7.4 は未インストール"
node --version 2>/dev/null || true
pm2 --version 2>/dev/null || true
mariadb --version 2>/dev/null || true
