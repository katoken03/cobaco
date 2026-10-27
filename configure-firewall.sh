#!/usr/bin/env bash
# configure-firewall.sh - UFW: Web / SSH 実ポート / メール(任意) のみ許可
# 使い方: root で bash configure-firewall.sh
# 環境変数:
#   MAIL_TCP_PORTS — カンマ区切り (既定: 587,465,993,995)。空文字でメール用ルールを追加しない
#   WEB_TCP_PORTS  — カンマ区切り (既定: 80,443)

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

WEB_TCP_PORTS="${WEB_TCP_PORTS:-80,443}"
MAIL_TCP_PORTS="${MAIL_TCP_PORTS:-587,465,993,995}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ssh-allow.sh
source "${SCRIPT_DIR}/lib/ssh-allow.sh"

mapfile -t SSH_LISTEN_PORTS < <(ssh_allow_listen_ports)

ssh_uses_non_default_port=false
for port in "${SSH_LISTEN_PORTS[@]}"; do
    if [[ "$port" != "22" ]]; then
        ssh_uses_non_default_port=true
        break
    fi
done

ufw_delete_loose() {
    local spec="$1"
    ufw delete allow "$spec" >/dev/null 2>&1 || true
    ufw delete allow "$spec" >/dev/null 2>&1 || true
}

info "UFW ルールを適用中..."

ssh_allow_mode="$(ssh_allow_state)"
if [[ "$ssh_allow_mode" == on ]]; then
    # 許可リストがあれば SSH は登録済みの接続元だけに開く
    ssh_allow_apply || warn "許可リストを適用できなかったため、SSH のルールは変更していません。"
else
    if [[ "$ssh_uses_non_default_port" == true ]]; then
        for port in "${SSH_LISTEN_PORTS[@]}"; do
            ufw allow "${port}/tcp" comment 'SSH'
        done
        ufw_delete_loose OpenSSH
        ufw_delete_loose 22/tcp
    else
        ufw allow OpenSSH
    fi
    if [[ "$ssh_allow_mode" == off ]]; then
        info "SSH は全体に公開しています (ssh-allow off により接続元の絞り込みをオフ)。"
    else
        warn "SSH は全体に公開されています。ssh-allow add <IP> <メモ> で接続元を限定するか、意図して公開するなら ssh-allow off を実行してください。"
    fi
fi

IFS=',' read -r -a web_ports <<< "$WEB_TCP_PORTS"
for port in "${web_ports[@]}"; do
    port="${port// /}"
    [[ -z "$port" ]] && continue
    ufw allow "${port}/tcp" comment 'Web'
done

if [[ -n "$MAIL_TCP_PORTS" ]]; then
    IFS=',' read -r -a mail_ports <<< "$MAIL_TCP_PORTS"
    for port in "${mail_ports[@]}"; do
        port="${port// /}"
        [[ -z "$port" ]] && continue
        if [[ "$port" == "25" ]]; then
            warn "ポート 25 は意図的に許可しません (スキップ)。"
            continue
        fi
        case "$port" in
            587) ufw allow "${port}/tcp" comment 'SMTP submission' ;;
            465) ufw allow "${port}/tcp" comment 'SMTPS' ;;
            993) ufw allow "${port}/tcp" comment 'IMAPS' ;;
            995) ufw allow "${port}/tcp" comment 'POP3S' ;;
            *)   ufw allow "${port}/tcp" comment 'Mail' ;;
        esac
    done
fi

ufw --force enable
success "ファイアウォール設定完了"
ufw status verbose

install -d -m 755 /usr/local/lib/cobaco
install -m 644 "${SCRIPT_DIR}/lib/ssh-allow.sh" /usr/local/lib/cobaco/ssh-allow.sh
install -m 755 "${SCRIPT_DIR}/bin/ssh-allow" /usr/local/sbin/ssh-allow
success "ssh-allow を配置しました: /usr/local/sbin/ssh-allow"
