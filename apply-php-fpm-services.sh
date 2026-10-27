#!/usr/bin/env bash
# apply-php-fpm-services.sh - domains.yml で使う PHP バージョンの FPM だけを動かす
# 使い方:
#   bash apply-php-fpm-services.sh            # 使っていない FPM を確認してから停止 (root)
#   bash apply-php-fpm-services.sh --dry-run  # 表示のみ
#   bash apply-php-fpm-services.sh --yes      # 確認せずに停止
# 停止は disable --now のみ (mask しない)。使うバージョンが止まっていれば起動する。

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    die "このスクリプトは root で実行してください。"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="/root/cobaco_config/domains.yml"

# COBACO_PHP_VERSIONS を共有する (source 時は本体を実行しない)
# shellcheck source=apply-php-fpm-ini.sh
source "${SCRIPT_DIR}/apply-php-fpm-ini.sh"

DRY_RUN=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes|-y)
            ASSUME_YES=true
            shift
            ;;
        *)
            die "不明なオプション: $1"
            ;;
    esac
done

if [[ ! -f "$DOMAINS_FILE" ]]; then
    info "domains.yml がないため、PHP-FPM の停止はスキップします (${DOMAINS_FILE})。"
    exit 0
fi

fpm_installed() {
    systemctl list-unit-files --no-legend "php${1}-fpm.service" 2>/dev/null | grep -q "^php${1}-fpm.service"
}

has_domain_pool() {
    local f
    for f in "/etc/php/${1}/fpm/pool.d"/*.conf; do
        [[ -e "$f" ]] || continue
        [[ "$(basename "$f")" == "www.conf" ]] && continue
        return 0
    done
    return 1
}

# domains.yml で type: php のドメインが使うバージョン
DECLARED_VERSIONS=" $(yq e '.domains[] | select(.type == "php") | .php_version' "$DOMAINS_FILE" \
    | awk '$0 != "null" && $0 != ""' | sort -u | tr '\n' ' ')"

STOP_CANDIDATES=()
for ver in "${COBACO_PHP_VERSIONS[@]}"; do
    fpm_installed "$ver" || continue
    svc="php${ver}-fpm"

    used=false
    if [[ "$DECLARED_VERSIONS" == *" ${ver} "* ]]; then
        used=true
    elif has_domain_pool "$ver"; then
        # 宣言はないがドメイン用プールが残っている: 安全のため止めない
        warn "PHP ${ver}: domains.yml にはありませんが、ドメイン用プールが残っています (/etc/php/${ver}/fpm/pool.d)。停止しません。"
        used=true
    fi

    if [[ "$used" == true ]]; then
        if ! systemctl is-active --quiet "$svc" || ! systemctl is-enabled --quiet "$svc"; then
            if [[ "$DRY_RUN" == true ]]; then
                info "[DRY-RUN] PHP ${ver}: 使用中のため起動予定 (${svc})"
            else
                systemctl enable --now "$svc" &>/dev/null
                success "PHP ${ver}: 使用中のため起動しました (${svc})"
            fi
        else
            info "PHP ${ver}: 使用中 (${svc})"
        fi
    elif systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc"; then
        STOP_CANDIDATES+=("$ver")
    else
        info "PHP ${ver}: 未使用・停止済み (${svc})"
    fi
done

if [[ ${#STOP_CANDIDATES[@]} -eq 0 ]]; then
    success "使っていない PHP-FPM は起動していません。"
    exit 0
fi

warn "どのドメインも使っていない PHP-FPM が起動しています: ${STOP_CANDIDATES[*]}"

if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 停止予定: ${STOP_CANDIDATES[*]}"
    exit 0
fi

if [[ "$ASSUME_YES" == false ]]; then
    if [[ ! -t 0 ]]; then
        info "端末がないため停止しませんでした (停止するには --yes を付けて実行)。"
        exit 0
    fi
    read -rp "不要な PHP-FPM を停止しますか? [y/N]: " ANSWER
    if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
        info "停止しませんでした。"
        exit 0
    fi
fi

for ver in "${STOP_CANDIDATES[@]}"; do
    systemctl disable --now "php${ver}-fpm" &>/dev/null
    success "PHP ${ver}: 停止しました (php${ver}-fpm)"
done
info "戻すとき: systemctl enable --now php<ver>-fpm (または domains.yml に書いて add-domain.sh を実行)"
