#!/usr/bin/env bash
# apply-php-fpm-ini.sh - バージョン共通 FPM ini (99-cobaco.ini) を配置して FPM を reload
# 使い方: root で bash apply-php-fpm-ini.sh
# setup.sh から source して install / reload 関数も利用する。

set -euo pipefail

COBACO_PHP_VERSIONS=(7.3 7.4 8.2 8.3 8.5)
COBACO_PHP_FPM_SERVICES=(php7.3-fpm php7.4-fpm php8.2-fpm php8.3-fpm php8.5-fpm)

install_cobaco_php_fpm_common_ini() {
    local ver="$1"
    local src="${COBACO_SCRIPT_DIR}/templates/php/${ver}/99-cobaco.ini"
    local dest="/etc/php/${ver}/fpm/conf.d/99-cobaco.ini"

    if [[ ! -f "/etc/php/${ver}/fpm/php.ini" ]]; then
        return 0
    fi
    if [[ ! -f "$src" ]]; then
        cobaco_warn "PHP ${ver}: テンプレートがありません (${src})。スキップします。"
        return 0
    fi
    cp "$src" "$dest"
    chmod 644 "$dest"
    cobaco_info "  PHP ${ver}: ${dest} を配置しました"
}

reload_cobaco_php_fpm_services() {
    local php_fpm_svc
    for php_fpm_svc in "${COBACO_PHP_FPM_SERVICES[@]}"; do
        if systemctl is-active --quiet "${php_fpm_svc}.service" 2>/dev/null; then
            systemctl reload "${php_fpm_svc}.service" || true
        fi
    done
}

apply_cobaco_php_fpm_ini() {
    local php_ver
    cobaco_info "cobaco PHP 共通 ini (FPM conf.d) を配置中..."
    for php_ver in "${COBACO_PHP_VERSIONS[@]}"; do
        install_cobaco_php_fpm_common_ini "$php_ver"
    done
    reload_cobaco_php_fpm_services
    cobaco_success "cobaco PHP 共通 ini の配置完了"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    NC='\033[0m'

    cobaco_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
    cobaco_success() { echo -e "${GREEN}[OK]${NC}   $*"; }
    cobaco_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
    cobaco_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

    if [[ $EUID -ne 0 ]]; then
        cobaco_error "このスクリプトは root で実行してください。"
        exit 1
    fi

    COBACO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    apply_cobaco_php_fpm_ini
fi
