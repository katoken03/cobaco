#!/usr/bin/env bash
# configure-nginx-default.sh - Nginx catch-all (default_server): 未知の Host / SNI を拒否
# 使い方: root で bash configure-nginx-default.sh
#   HTTP は 444 で切断、HTTPS は ssl_reject_handshake でハンドシェイクを拒否する

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

if [[ $EUID -ne 0 ]]; then
    error "このスクリプトは root で実行してください。"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/templates/nginx-default.conf"
CONF_FILE="/etc/nginx/sites-available/cobaco-default"
LINK_FILE="/etc/nginx/sites-enabled/cobaco-default"

if [[ ! -f "$TEMPLATE" ]]; then
    error "テンプレートが見つかりません: ${TEMPLATE}"
    exit 1
fi

if ! command -v nginx &>/dev/null; then
    error "nginx がインストールされていません。"
    exit 1
fi

# ssl_reject_handshake は nginx 1.19.4 以降
NGINX_VERSION="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"
SUPPORTS_REJECT_HANDSHAKE=true
if [[ -z "$NGINX_VERSION" ]] \
    || [[ "$(printf '%s\n' "1.19.4" "$NGINX_VERSION" | sort -V | head -n1)" != "1.19.4" ]]; then
    SUPPORTS_REJECT_HANDSHAKE=false
fi

# 失敗時に戻せるよう、配置前の状態を退避する
BACKUP_FILE=""
if [[ -f "$CONF_FILE" ]]; then
    BACKUP_FILE="$(mktemp)"
    cp -p "$CONF_FILE" "$BACKUP_FILE"
fi
HAD_LINK=false
[[ -L "$LINK_FILE" ]] && HAD_LINK=true

rollback() {
    if [[ -n "$BACKUP_FILE" ]]; then
        cp -p "$BACKUP_FILE" "$CONF_FILE"
    else
        rm -f "$CONF_FILE"
    fi
    if [[ "$HAD_LINK" == false ]]; then
        rm -f "$LINK_FILE"
    fi
}

if [[ "$SUPPORTS_REJECT_HANDSHAKE" == true ]]; then
    install -m 644 "$TEMPLATE" "$CONF_FILE"
else
    warn "nginx ${NGINX_VERSION:-(不明)} は ssl_reject_handshake に対応していません (1.19.4 以降が必要)。HTTP (80) の catch-all のみ配置します。"
    # 2 つ目の server ブロック (443) を除く
    awk '/^server \{/ { n++ } n <= 1' "$TEMPLATE" > "$CONF_FILE"
    chmod 644 "$CONF_FILE"
fi
ln -sf "$CONF_FILE" "$LINK_FILE"

if ! nginx -t &>/dev/null; then
    rollback
    [[ -n "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE"
    error "nginx -t に失敗したため、catch-all の配置を元に戻しました。詳細: nginx -t"
    exit 1
fi
[[ -n "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE"

systemctl reload nginx
success "Nginx catch-all を配置しました: ${CONF_FILE}"

info "確認: curl -sv http://<サーバーのIP>/  → Empty reply from server"
info "確認: curl -skv https://<サーバーのIP>/ → ハンドシェイク失敗 (証明書が返らない)"
info "ログ: /var/log/nginx/default-catchall-access.log"
