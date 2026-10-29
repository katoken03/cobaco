#!/usr/bin/env bash
# setup.sh - VPS 初回セットアップスクリプト
# 使い方: root で bash setup.sh
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
    error "このスクリプトは root で実行してください。"
    exit 1
fi

# スクリプト自身のディレクトリを記録 (templates/ 等へのパスに使用)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────
# Ubuntu バージョン確認・警告
# ─────────────────────────────────────────────
# shellcheck source=/dev/null
source /etc/os-release
UBUNTU_CODENAME="${VERSION_CODENAME:-unknown}"
UBUNTU_VERSION="${VERSION_ID:-unknown}"
UBUNTU_MAJOR="${UBUNTU_VERSION%%.*}"
USE_SURY_PHP=false
if [[ "$UBUNTU_MAJOR" =~ ^[0-9]+$ ]] && (( UBUNTU_MAJOR >= 26 )); then
    USE_SURY_PHP=true
fi

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
    ripgrep \
    fd-find \
    software-properties-common \
    ufw \
    fail2ban \
    nginx \
    apache2-utils \
    mariadb-server \
    certbot \
    python3-certbot-nginx
# Ubuntu の fd-find は fdfind。AGENTS.md の fd 慣習に合わせ fd も使えるようにする
ln -sfn "$(command -v fdfind)" /usr/local/bin/fd
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

# 未知の Host / SNI を拒否する catch-all (default_server)
bash "${SCRIPT_DIR}/configure-nginx-default.sh"

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
# PHP マルチバージョン
# ─────────────────────────────────────────────
install_php73_fpm() {
    if ! apt-cache show php7.3-fpm &>/dev/null; then
        error "PHP 7.3 (php7.3-fpm) が利用できません。Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}) 向けのリポジトリを確認してください。"
        exit 1
    fi
    info "PHP 7.3 をインストール中..."
    apt-get install -y -qq \
        php7.3-fpm \
        php7.3-mysql \
        php7.3-curl \
        php7.3-mbstring \
        php7.3-xml \
        php7.3-zip \
        php7.3-gd \
        php7.3-bcmath \
        php7.3-opcache
    systemctl enable php7.3-fpm
    systemctl start php7.3-fpm
    success "PHP 7.3 のインストール完了"
}

install_php74_fpm() {
    if ! apt-cache show php7.4-fpm &>/dev/null; then
        error "PHP 7.4 (php7.4-fpm) が利用できません。Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}) 向けのリポジトリを確認してください。"
        exit 1
    fi
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
}

install_php82_fpm() {
    if ! apt-cache show php8.2-fpm &>/dev/null; then
        error "PHP 8.2 (php8.2-fpm) が利用できません。Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}) 向けのリポジトリを確認してください。"
        exit 1
    fi
    info "PHP 8.2 をインストール中..."
    apt-get install -y -qq \
        php8.2-fpm \
        php8.2-mysql \
        php8.2-curl \
        php8.2-mbstring \
        php8.2-xml \
        php8.2-zip \
        php8.2-intl \
        php8.2-gd \
        php8.2-bcmath
    systemctl enable php8.2-fpm
    systemctl start php8.2-fpm
    success "PHP 8.2 のインストール完了"
}

install_php83_fpm() {
    if ! apt-cache show php8.3-fpm &>/dev/null; then
        error "PHP 8.3 (php8.3-fpm) が利用できません。Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}) 向けのリポジトリを確認してください。"
        exit 1
    fi
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
        php8.3-bcmath
    systemctl enable php8.3-fpm
    systemctl start php8.3-fpm
    success "PHP 8.3 のインストール完了"
}

install_php85_fpm() {
    if ! apt-cache show php8.5-fpm &>/dev/null; then
        error "PHP 8.5 (php8.5-fpm) が利用できません。Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}) 向けのリポジトリを確認してください。"
        exit 1
    fi
    info "PHP 8.5 をインストール中..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        php8.5-fpm \
        php8.5-mysql \
        php8.5-curl \
        php8.5-mbstring \
        php8.5-xml \
        php8.5-zip \
        php8.5-intl \
        php8.5-gd \
        php8.5-bcmath
    systemctl enable php8.5-fpm
    systemctl start php8.5-fpm
    success "PHP 8.5 のインストール完了"
}

if [[ "$USE_SURY_PHP" == true ]]; then
    # Ubuntu 26 以降: PHP 8.5 / 7.3 / 7.4 / 8.2 / 8.3 は packages.sury.org
    info "packages.sury.org (PHP 8.5 / 7.3 / 7.4 / 8.2 / 8.3) を追加中..."
    curl -sSLo /tmp/debsuryorg-archive-keyring.deb \
        https://packages.sury.org/debsuryorg-archive-keyring.deb
    dpkg -i /tmp/debsuryorg-archive-keyring.deb
    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${UBUNTU_CODENAME} main" \
        > /etc/apt/sources.list.d/php-sury.list

    cat > /etc/apt/preferences.d/sury-php << 'EOF'
Package: *
Pin: origin packages.sury.org
Pin-Priority: 100

Package: php-common
Pin: origin packages.sury.org
Pin-Priority: 500

Package: php7.3*
Pin: origin packages.sury.org
Pin-Priority: 500

Package: php7.4*
Pin: origin packages.sury.org
Pin-Priority: 500

Package: php8.2*
Pin: origin packages.sury.org
Pin-Priority: 500

Package: php8.3*
Pin: origin packages.sury.org
Pin-Priority: 500

Package: php8.5*
Pin: origin packages.sury.org
Pin-Priority: 500
EOF

    apt-get update -qq
    success "packages.sury.org の追加完了"

    install_php85_fpm
    install_php73_fpm
    install_php74_fpm
    install_php82_fpm
    install_php83_fpm
else
    info "ondrej/php PPA を追加中..."
    # --no-update: apt-get update を自動実行させない (suite 書き換え後に手動で実行する)
    add-apt-repository -y --no-update ppa:ondrej/php

    # ondrej/php PPA は LTS のみサポート。非 LTS (plucky 等) の場合は noble に書き換える
    SOURCES_FILE=$(find /etc/apt/sources.list.d/ -name "*ondrej*php*" | head -1)
    if [[ -n "$SOURCES_FILE" ]] && grep -q "Suites: ${UBUNTU_CODENAME}" "$SOURCES_FILE"; then
        if ! curl -sf "https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/${UBUNTU_CODENAME}/Release" -o /dev/null; then
            warn "ondrej/php PPA は ${UBUNTU_CODENAME} 未対応のため、noble (24.04 LTS) のパッケージを使用します。"
            sed -i "s/^Suites:.*/Suites: noble/" "$SOURCES_FILE"
        fi
    fi

    apt-get update -qq
    success "PPA の追加完了"

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

    install_php74_fpm
fi

# cobaco: バージョン共通 FPM ini と、ドメイン用プールがあるときの www 退避
COBACO_SCRIPT_DIR="$SCRIPT_DIR"
cobaco_info()    { info "$@"; }
cobaco_success() { success "$@"; }
cobaco_warn()    { warn "$@"; }
# shellcheck source=apply-php-fpm-ini.sh
source "${SCRIPT_DIR}/apply-php-fpm-ini.sh"

retire_default_php_fpm_www_pool_if_needed() {
    local ver="$1"
    local pool_dir="/etc/php/${ver}/fpm/pool.d"
    local www_conf="${pool_dir}/www.conf"

    [[ -d "$pool_dir" ]] || return 0

    local has_domain_pool=false
    local f base
    for f in "$pool_dir"/*.conf; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f")
        [[ "$base" == "www.conf" ]] && continue
        has_domain_pool=true
        break
    done

    if [[ "$has_domain_pool" == true && -f "$www_conf" ]]; then
        mv "$www_conf" "${www_conf}.disabled"
        info "  PHP ${ver}: www.conf を www.conf.disabled に退避しました"
    fi
}

info "cobaco PHP 共通 ini (FPM conf.d) を配置中..."
for php_ver in 7.3 7.4 8.2 8.3 8.5; do
    install_cobaco_php_fpm_common_ini "$php_ver"
    retire_default_php_fpm_www_pool_if_needed "$php_ver"
done
reload_cobaco_php_fpm_services
success "cobaco PHP 共通 ini の配置完了"

# PHP-FPM: グループ書き込み可能なファイルを www-data が作成できるよう UMask を設定
info "PHP-FPM の UMask=0002 を設定中..."
for php_fpm_svc in php7.3-fpm php7.4-fpm php8.2-fpm php8.3-fpm php8.5-fpm; do
    if systemctl list-unit-files "${php_fpm_svc}.service" 2>/dev/null | grep -q "^${php_fpm_svc}.service"; then
        mkdir -p "/etc/systemd/system/${php_fpm_svc}.service.d"
        cat > "/etc/systemd/system/${php_fpm_svc}.service.d/umask.conf" << 'EOF'
[Service]
UMask=0002
EOF
        info "  ${php_fpm_svc}: drop-in を配置しました"
    fi
done
systemctl daemon-reload

# www-data を cobaco グループに追加 (Nginx / PHP-FPM が cobaco 所有の 775 等を読める)
www_data_in_cobaco_group=false
if id cobaco &>/dev/null && id www-data &>/dev/null; then
    if id -nG www-data | tr ' ' '\n' | grep -qx cobaco; then
        info "www-data は既に cobaco グループに所属しています"
        www_data_in_cobaco_group=true
    else
        usermod -aG cobaco www-data
        www_data_in_cobaco_group=true
        success "www-data を cobaco グループに追加しました"
    fi
else
    warn "cobaco または www-data が未作成のため、www-data の cobaco グループ追加をスキップしました (SETUP_USERS.md Step 2)。"
fi

for php_fpm_svc in php7.3-fpm php7.4-fpm php8.2-fpm php8.3-fpm php8.5-fpm; do
    if systemctl is-enabled "${php_fpm_svc}.service" &>/dev/null; then
        systemctl restart "${php_fpm_svc}.service" || true
    fi
done
if [[ "$www_data_in_cobaco_group" == true ]] && systemctl is-enabled nginx.service &>/dev/null; then
    systemctl restart nginx.service || true
fi
success "PHP-FPM UMask 設定完了"

# cobaco 運用ログ
mkdir -p /var/log/cobaco
if id cobaco &>/dev/null; then
    chown cobaco:cobaco /var/log/cobaco
else
    warn "cobaco ユーザーが未作成です。/var/log/cobaco の所有者は root のままです (SETUP_USERS.md Step 2)。"
fi
chmod 755 /var/log/cobaco

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
pm2_version() { node -p "require('$(npm root -g)/pm2/package.json').version"; }
if ! npm list -g pm2 &>/dev/null; then
    info "PM2 をグローバルインストール中..."
    npm install -g pm2
    # pm2 コマンドはデーモンを起動してしまうため、バージョンは package.json から読む
    success "PM2 $(pm2_version) のインストール完了"
else
    success "PM2 は既にインストール済み"
fi

# PM2 systemd スタートアップ設定 (cobaco ユーザー)
info "PM2 systemd スタートアップを設定中..."
if id cobaco &>/dev/null; then
    # shellcheck disable=SC2016
    sudo -u cobaco bash -lc 'export NVM_DIR="/opt/nvm"; . "$NVM_DIR/nvm.sh"; command -v pm2 >/dev/null || npm install -g pm2'
    sudo -u cobaco bash -lc 'export NVM_DIR="/opt/nvm"; . "$NVM_DIR/nvm.sh"; pm2 startup systemd -u cobaco --hp /home/cobaco' | tail -1 | bash || true
    success "PM2 スタートアップ設定完了 (ユーザー: cobaco)"
else
    warn "cobaco ユーザーが未作成のため PM2 スタートアップをスキップしました。"
    warn "SETUP_USERS.md Step 2 の後、setup.sh を再実行するか、手動で pm2 startup を設定してください。"
fi

# PM2 ログローテーション (Nginx と同様 daily / 14 世代)
if id cobaco &>/dev/null; then
    mkdir -p /home/cobaco/.pm2/logs
    chown -R cobaco:cobaco /home/cobaco/.pm2
fi
cat > /etc/logrotate.d/cobaco-pm2 << 'EOF'
/home/cobaco/.pm2/pm2.log
/home/cobaco/.pm2/logs/*.log
{
    daily
    rotate 14
    maxsize 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
success "PM2 ログローテーション設定完了 (/etc/logrotate.d/cobaco-pm2)"

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
bash "${SCRIPT_DIR}/configure-firewall.sh"

# ─────────────────────────────────────────────
# fail2ban (sshd: 全ポート遮断)
# ─────────────────────────────────────────────
info "fail2ban を設定中..."
bash "${SCRIPT_DIR}/configure-fail2ban.sh"

# ─────────────────────────────────────────────
# OS の調整 (ICMP リダイレクト無効化・不要サービス停止・root PM2 停止)
# ─────────────────────────────────────────────
info "OS を調整中..."
bash "${SCRIPT_DIR}/configure-os.sh"

# ─────────────────────────────────────────────
# 本番用設定ディレクトリ (Git 作業ツリー外)
# ─────────────────────────────────────────────
COBACO_CONFIG_DIR="/root/cobaco_config"
if [[ ! -d "$COBACO_CONFIG_DIR" ]]; then
    mkdir -m 755 "$COBACO_CONFIG_DIR"
    success "設定ディレクトリを作成: ${COBACO_CONFIG_DIR}"
fi

# ─────────────────────────────────────────────
# サーバー監視 (Webhook 通知)
# ─────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/install-monitor.sh" ]]; then
    info "サーバー監視 (monitor) をセットアップ中..."
    bash "${SCRIPT_DIR}/install-monitor.sh"
fi

# ─────────────────────────────────────────────
# 使っていない PHP-FPM の停止 (domains.yml がなければスキップ・確認あり)
# ─────────────────────────────────────────────
bash "${SCRIPT_DIR}/apply-php-fpm-services.sh"

# ─────────────────────────────────────────────
# 完了メッセージ
# ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  セットアップが完了しました!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "次のステップ:"
echo "  1. domains.yml.sample を ${COBACO_CONFIG_DIR}/domains.yml にコピーして編集する"
echo "     (cobaco が読めるよう: chmod 711 /root && chmod 644 ${COBACO_CONFIG_DIR}/domains.yml)"
echo "  2. bash add-domain.sh <ドメイン名> を実行する (root)"
echo "  3. bash install-cli.sh で cobaco コマンド (対話メニュー) を導入する"
echo ""
info "インストール済みバージョン:"
nginx -v 2>&1 || true
if [[ "$USE_SURY_PHP" == true ]]; then
    php8.5 --version | head -1 || true
else
    php8.3 --version | head -1 || true
fi
php7.4 --version 2>/dev/null | head -1 || warn "PHP 7.4 は未インストール"
node --version 2>/dev/null || true
echo "pm2 $(pm2_version 2>/dev/null)" || true
mariadb --version 2>/dev/null || true
