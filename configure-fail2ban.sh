#!/usr/bin/env bash
# configure-fail2ban.sh - fail2ban sshd jail: BAN した IP を全ポートで遮断
# 使い方: root で bash configure-fail2ban.sh
# 環境変数:
#   F2B_SSHD_BANTIME  — BAN 秒数 (既定: 86400)
#   F2B_SSHD_FINDTIME — 失敗を数える期間の秒数 (既定: 600)
#   F2B_SSHD_MAXRETRY — BAN までの失敗回数 (既定: 5)

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

F2B_SSHD_BANTIME="${F2B_SSHD_BANTIME:-86400}"
F2B_SSHD_FINDTIME="${F2B_SSHD_FINDTIME:-600}"
F2B_SSHD_MAXRETRY="${F2B_SSHD_MAXRETRY:-5}"

JAIL_FILE="/etc/fail2ban/jail.d/cobaco-sshd.local"
LEGACY_JAIL_LOCAL="/etc/fail2ban/jail.local"

if ! command -v fail2ban-client &>/dev/null; then
    info "fail2ban をインストール中..."
    apt-get install -y -qq fail2ban
fi

# jail.d/*.local は jail.local より後に読まれるため、手書きの jail.local の [sshd] より優先される
if [[ -f "$LEGACY_JAIL_LOCAL" ]] && awk '/^[[:space:]]*\[sshd\]/ { found = 1 } END { exit !found }' "$LEGACY_JAIL_LOCAL"; then
    warn "${LEGACY_JAIL_LOCAL} に [sshd] があります。${JAIL_FILE} の設定が優先されます。"
fi

backup=""
if [[ -f "$JAIL_FILE" ]]; then
    backup="$(mktemp)"
    cp -p "$JAIL_FILE" "$backup"
fi

info "${JAIL_FILE} を生成中..."
mkdir -p "$(dirname "$JAIL_FILE")"
cat > "$JAIL_FILE" <<EOF
# cobaco: configure-fail2ban.sh が生成。手で編集しない
[sshd]
enabled   = true
backend   = systemd
banaction = %(banaction_allports)s
bantime   = ${F2B_SSHD_BANTIME}
findtime  = ${F2B_SSHD_FINDTIME}
maxretry  = ${F2B_SSHD_MAXRETRY}
EOF
chmod 644 "$JAIL_FILE"

if ! fail2ban-client -t >/dev/null; then
    error "fail2ban の設定検査に失敗しました。${JAIL_FILE} を元に戻します。"
    if [[ -n "$backup" ]]; then
        mv "$backup" "$JAIL_FILE"
    else
        rm -f "$JAIL_FILE"
    fi
    exit 1
fi
[[ -n "$backup" ]] && rm -f "$backup"

systemctl enable fail2ban.service >/dev/null 2>&1 || true
if systemctl is-active --quiet fail2ban.service; then
    fail2ban-client reload
else
    systemctl start fail2ban.service
fi
success "fail2ban 設定完了 (sshd: 全ポート遮断)"
fail2ban-client status sshd
