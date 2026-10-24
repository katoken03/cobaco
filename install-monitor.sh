#!/usr/bin/env bash
# install-monitor.sh - サーバー監視 (monitor.sh) の systemd timer と logrotate を配置
# 使い方: root で bash install-monitor.sh

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
MONITOR_SCRIPT="${SCRIPT_DIR}/monitor.sh"
COBACO_CONFIG_DIR="/root/cobaco_config"
MONITOR_CONFIG="${COBACO_CONFIG_DIR}/monitor.yml"
MONITOR_SAMPLE="${SCRIPT_DIR}/monitor.yml.sample"

if [[ ! -x "$MONITOR_SCRIPT" ]] && [[ -f "$MONITOR_SCRIPT" ]]; then
    chmod +x "$MONITOR_SCRIPT"
fi

if [[ ! -f "$MONITOR_SCRIPT" ]]; then
    error "monitor.sh が見つかりません: ${MONITOR_SCRIPT}"
    exit 1
fi

mkdir -p "$COBACO_CONFIG_DIR"
mkdir -p /var/lib/cobaco/monitor
mkdir -p /var/log/cobaco

if [[ ! -f "$MONITOR_CONFIG" ]]; then
    if [[ ! -f "$MONITOR_SAMPLE" ]]; then
        error "monitor.yml.sample が見つかりません: ${MONITOR_SAMPLE}"
        exit 1
    fi
    cp "$MONITOR_SAMPLE" "$MONITOR_CONFIG"
    chmod 600 "$MONITOR_CONFIG"
    success "設定を作成: ${MONITOR_CONFIG} (Webhook URL を編集してください)"
else
    success "設定は既存のまま: ${MONITOR_CONFIG}"
fi

info "systemd unit を配置中..."
cat > /etc/systemd/system/cobaco-monitor.service << EOF
[Unit]
Description=cobaco server health monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${MONITOR_SCRIPT}
User=root
EOF

cat > /etc/systemd/system/cobaco-monitor.timer << 'EOF'
[Unit]
Description=Run cobaco server monitor every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable cobaco-monitor.timer
systemctl start cobaco-monitor.timer
success "cobaco-monitor.timer を有効化しました"

info "logrotate を配置中..."
cat > /etc/logrotate.d/cobaco-monitor << 'EOF'
/var/log/cobaco/monitor.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
success "logrotate: /etc/logrotate.d/cobaco-monitor"

echo ""
info "次のステップ:"
echo "  1. ${MONITOR_CONFIG} に webhook.url と webhook.format を設定"
echo "  2. bash ${MONITOR_SCRIPT} --test-notify"
echo "  3. systemctl status cobaco-monitor.timer"
