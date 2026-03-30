#!/usr/bin/env bash
# deploy.sh - ドメインのデプロイスクリプト (git pull + ビルド + 再起動)
# 使い方:
#   sudo bash deploy.sh example.com         # 単一ドメインをデプロイ
#   sudo bash deploy.sh --all               # domains.yml の全ドメインをデプロイ
#   sudo bash deploy.sh --branch main example.com  # ブランチ指定

set -euo pipefail

# ─────────────────────────────────────────────
# 色付き出力ヘルパー
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# root 確認
# ─────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    die "このスクリプトは root (sudo) で実行してください。"
fi

# スクリプト自身のディレクトリ
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="${SCRIPT_DIR}/domains.yml"

# nvm のパスを読み込む (Node.js が必要なドメイン向け)
NVM_DIR="/opt/nvm"
if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NVM_DIR}/nvm.sh"
fi

# ─────────────────────────────────────────────
# 引数の解析
# ─────────────────────────────────────────────
DEPLOY_ALL=false
BRANCH="main"
TARGET_DOMAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            DEPLOY_ALL=true
            shift
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        -*)
            die "不明なオプション: $1"
            ;;
        *)
            TARGET_DOMAIN="$1"
            shift
            ;;
    esac
done

if [[ "$DEPLOY_ALL" == false && -z "$TARGET_DOMAIN" ]]; then
    echo "使い方:"
    echo "  sudo bash deploy.sh <ドメイン名>"
    echo "  sudo bash deploy.sh --all"
    echo "  sudo bash deploy.sh --branch main <ドメイン名>"
    exit 1
fi

# ─────────────────────────────────────────────
# 前提条件の確認
# ─────────────────────────────────────────────
[[ -f "$DOMAINS_FILE" ]] || die "domains.yml が見つかりません: ${DOMAINS_FILE}"
command -v yq &>/dev/null || die "yq がインストールされていません。先に setup.sh を実行してください。"

# ─────────────────────────────────────────────
# デプロイ関数
# ─────────────────────────────────────────────
deploy_domain() {
    local domain="$1"
    info "=== ${domain} のデプロイを開始 (ブランチ: ${BRANCH}) ==="

    # domains.yml から type と pm2_name を取得
    local type
    type=$(yq e ".domains[] | select(.name == \"${domain}\") | .type" "$DOMAINS_FILE")
    [[ -n "$type" && "$type" != "null" ]] || die "[${domain}] domains.yml に設定が見つかりません。"

    local webroot
    if [[ "$type" == "php" ]]; then
        webroot="/var/www/${domain}"
    else
        webroot="/var/www/${domain}"
    fi

    [[ -d "$webroot" ]] || die "[${domain}] ディレクトリが存在しません: ${webroot}\n  先に add-domain.sh を実行してください。"
    [[ -d "${webroot}/.git" ]] || die "[${domain}] Git リポジトリが初期化されていません: ${webroot}\n  git clone でリポジトリをセットアップしてください。"

    # git pull
    info "git pull origin ${BRANCH} を実行中..."
    cd "$webroot"
    git fetch origin
    git checkout "$BRANCH"
    git pull origin "$BRANCH"
    success "git pull 完了"

    # type 別のビルド・再起動
    if [[ "$type" == "php" ]]; then
        deploy_php "$domain" "$webroot"
    elif [[ "$type" == "nodejs" ]]; then
        deploy_nodejs "$domain" "$webroot"
    fi

    success "=== ${domain} のデプロイが完了しました ==="
    echo ""
}

deploy_php() {
    local domain="$1"
    local webroot="$2"

    # composer.json があれば composer install を実行
    if [[ -f "${webroot}/composer.json" ]]; then
        if command -v composer &>/dev/null; then
            info "composer install を実行中..."
            cd "$webroot"
            composer install --no-dev --optimize-autoloader --no-interaction
            success "composer install 完了"
        else
            warn "composer がインストールされていません。スキップします。"
            warn "インストール: curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"
        fi
    fi

    # php_version を取得して FPM を再起動
    local php_version
    php_version=$(yq e ".domains[] | select(.name == \"${domain}\") | .php_version" "$DOMAINS_FILE")
    if systemctl is-active --quiet "php${php_version}-fpm"; then
        systemctl reload "php${php_version}-fpm"
        success "PHP ${php_version}-FPM をリロードしました。"
    fi
}

deploy_nodejs() {
    local domain="$1"
    local webroot="$2"

    local pm2_name
    pm2_name=$(yq e ".domains[] | select(.name == \"${domain}\") | .pm2_name" "$DOMAINS_FILE")

    # package.json の存在確認
    [[ -f "${webroot}/package.json" ]] || die "[${domain}] package.json が見つかりません: ${webroot}"

    # npm ci でクリーンインストール
    info "npm ci を実行中..."
    cd "$webroot"
    npm ci
    success "npm ci 完了"

    # npm run build (scripts に build があれば)
    if node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1);" 2>/dev/null; then
        info "npm run build を実行中..."
        npm run build
        success "npm run build 完了"
    else
        info "package.json に build スクリプトがないためスキップします。"
    fi

    # PM2 プロセスの再起動 (存在しない場合は起動)
    if pm2 describe "$pm2_name" &>/dev/null; then
        info "PM2 プロセス '${pm2_name}' を再起動中..."
        pm2 restart "$pm2_name"
        success "PM2 再起動完了"
    else
        info "PM2 プロセス '${pm2_name}' を新規起動中..."
        pm2 start npm --name "$pm2_name" -- start
        pm2 save
        success "PM2 起動・保存完了"
    fi
}

# ─────────────────────────────────────────────
# メイン処理
# ─────────────────────────────────────────────
if [[ "$DEPLOY_ALL" == true ]]; then
    info "domains.yml の全ドメインをデプロイします..."
    ALL_DOMAINS=$(yq e '.domains[].name' "$DOMAINS_FILE")
    FAILED_DOMAINS=()
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        if ! deploy_domain "$domain"; then
            FAILED_DOMAINS+=("$domain")
            warn "${domain} のデプロイに失敗しました。続行します。"
        fi
    done <<< "$ALL_DOMAINS"

    if [[ ${#FAILED_DOMAINS[@]} -gt 0 ]]; then
        error "以下のドメインのデプロイに失敗しました:"
        for d in "${FAILED_DOMAINS[@]}"; do
            error "  - $d"
        done
        exit 1
    fi
    success "全ドメインのデプロイが完了しました。"
else
    deploy_domain "$TARGET_DOMAIN"
fi
