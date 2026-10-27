#!/usr/bin/env bash
# configure-os.sh - OS の調整: ICMP リダイレクト送信の無効化・不要サービスの停止・root PM2 の停止
# 使い方: root で bash configure-os.sh
# 再実行しても安全 (冪等性を考慮)

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

# ─────────────────────────────────────────────
# sysctl: ICMP リダイレクトを送らない (ルーターではないため)
# ─────────────────────────────────────────────
SYSCTL_FILE="/etc/sysctl.d/60-cobaco.conf"

# send_redirects の実効値は all と各インターフェースの OR。
# 既存の eth0 などにも効かせるため glob 行も置く (systemd-sysctl と udev の
# インターフェース追加時の適用は glob に対応している)
cat > "$SYSCTL_FILE" << 'EOF'
# cobaco: configure-os.sh が配置
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.*.send_redirects = 0
EOF
chmod 644 "$SYSCTL_FILE"

/usr/lib/systemd/systemd-sysctl "$SYSCTL_FILE"

REMAINING=""
for f in /proc/sys/net/ipv4/conf/*/send_redirects; do
    if [[ "$(cat "$f")" != "0" ]]; then
        REMAINING+=" $(basename "$(dirname "$f")")"
    fi
done
if [[ -n "$REMAINING" ]]; then
    warn "send_redirects が 0 になっていないインターフェースがあります:${REMAINING}"
else
    success "send_redirects を無効化しました (${SYSCTL_FILE})"
fi

# ─────────────────────────────────────────────
# VPS で使わないサービスを停止・mask
# ─────────────────────────────────────────────
UNUSED_UNITS=(ModemManager.service udisks2.service upower.service)

for unit in "${UNUSED_UNITS[@]}"; do
    if [[ -z "$(systemctl list-unit-files --no-legend "$unit" 2>/dev/null)" ]]; then
        info "${unit} は未インストールです。スキップします。"
        continue
    fi
    if [[ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" == "masked" ]] \
        && ! systemctl is-active --quiet "$unit"; then
        info "${unit} は停止済み (masked) です。"
        continue
    fi
    systemctl disable --now "$unit" &>/dev/null || true
    systemctl mask "$unit" &>/dev/null
    success "${unit} を停止し mask しました。"
done
info "戻すとき: systemctl unmask <unit> && systemctl enable --now <unit>"

# ─────────────────────────────────────────────
# root の PM2 デーモン (アプリは cobaco の PM2 で動かす)
# ─────────────────────────────────────────────
# pm2 コマンドはデーモンがなければ起動してしまうため、先に PID で生存を確認する
ROOT_PM2_PID_FILE="/root/.pm2/pm2.pid"
ROOT_PM2_PID=""
[[ -f "$ROOT_PM2_PID_FILE" ]] && ROOT_PM2_PID="$(cat "$ROOT_PM2_PID_FILE")"

if [[ -z "$ROOT_PM2_PID" ]] || ! kill -0 "$ROOT_PM2_PID" 2>/dev/null; then
    info "root の PM2 デーモンは起動していません。"
else
    # shellcheck disable=SC2016
    ROOT_PM2_APPS="$(bash -c 'export NVM_DIR="/opt/nvm"; . "$NVM_DIR/nvm.sh"; set -o pipefail
        pm2 jlist | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).length))"' \
        2>/dev/null || echo "unknown")"
    if [[ "$ROOT_PM2_APPS" == "0" ]]; then
        # shellcheck disable=SC2016
        bash -c 'export NVM_DIR="/opt/nvm"; . "$NVM_DIR/nvm.sh"; pm2 kill' &>/dev/null
        success "アプリのない root の PM2 デーモンを停止しました。"
    elif [[ "$ROOT_PM2_APPS" == "unknown" ]]; then
        warn "root の PM2 のアプリ一覧を取得できませんでした。停止せずに残します (確認: pm2 list)。"
    else
        warn "root の PM2 で ${ROOT_PM2_APPS} 件のアプリが動いています。停止せずに残します。"
        warn "アプリは cobaco ユーザーの PM2 に移してください (root 権限で動かさない)。"
    fi
fi
