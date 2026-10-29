#!/usr/bin/env bash
# install-cli.sh - cobaco コマンド (対話メニュー) をビルドして /usr/local/bin/cobaco に配置
# 使い方: root で bash install-cli.sh
# 再実行しても安全 (git pull 後に再実行すると再ビルドする)

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
CLI_DIR="${SCRIPT_DIR}/cli"
BUN_VERSION="1.3.11"
BUN_INSTALL="/usr/local/lib/bun"
BUN="${BUN_INSTALL}/bin/bun"
COBACO_BIN="/usr/local/bin/cobaco"

# ─────────────────────────────────────────────
# bun (ビルド専用。実行時には不要)
# ─────────────────────────────────────────────
if [[ -x "$BUN" && "$("$BUN" --version)" == "$BUN_VERSION" ]]; then
    success "bun ${BUN_VERSION} はインストール済み"
else
    info "bun ${BUN_VERSION} を ${BUN_INSTALL} にインストール中..."
    case "$(uname -m)" in
        x86_64)  bun_arch="x64" ;;
        aarch64) bun_arch="aarch64" ;;
        *) error "未対応の CPU です: $(uname -m)"; exit 1 ;;
    esac
    command -v unzip &>/dev/null || apt-get install -y unzip
    # 公式インストーラーはシェルの rc を書き換えるため、リリースの zip を直接展開する
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "${tmp}/bun.zip" \
        "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}.zip"
    unzip -q "${tmp}/bun.zip" -d "$tmp"
    install -D -m 755 "${tmp}/bun-linux-${bun_arch}/bun" "$BUN"
    success "bun $("$BUN" --version) のインストール完了"
fi

# ─────────────────────────────────────────────
# ビルド
# ─────────────────────────────────────────────
info "cobaco コマンドをビルド中..."
(
    cd "$CLI_DIR"
    # package.json の build スクリプトは PATH 上の bun を呼ぶ
    export PATH="$(dirname "$BUN"):$PATH"
    "$BUN" install --frozen-lockfile
    "$BUN" run build
)
chmod 755 "${CLI_DIR}/cobaco"
success "ビルド完了: ${CLI_DIR}/cobaco"

# リポジトリ直下を探すためシンボリックリンクにする (コピーするとスクリプトが見つからない)
ln -sfn "${CLI_DIR}/cobaco" "$COBACO_BIN"
success "${COBACO_BIN} -> ${CLI_DIR}/cobaco"

if id cobaco &>/dev/null && ! sudo -u cobaco test -x "${CLI_DIR}/cobaco" 2>/dev/null; then
    warn "cobaco ユーザーから ${CLI_DIR}/cobaco を実行できません。リポジトリの権限を確認してください。"
fi

echo ""
echo "引数なしで cobaco を実行するとメニューが開きます。"
