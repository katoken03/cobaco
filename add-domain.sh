#!/usr/bin/env bash
# add-domain.sh - ドメイン追加・Nginx 設定生成スクリプト
# 使い方:
#   sudo bash add-domain.sh example.com        # 単一ドメインを設定
#   sudo bash add-domain.sh --all              # domains.yml の全ドメインを一括設定
#   sudo bash add-domain.sh --dry-run example.com  # 変更せず検証のみ実行

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
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# ─────────────────────────────────────────────
# 引数の解析
# ─────────────────────────────────────────────
DRY_RUN=false
TARGET_DOMAIN=""
ADD_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --all)
            ADD_ALL=true
            shift
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

if [[ "$ADD_ALL" == false && -z "$TARGET_DOMAIN" ]]; then
    echo "使い方:"
    echo "  sudo bash add-domain.sh <ドメイン名>"
    echo "  sudo bash add-domain.sh --all"
    echo "  sudo bash add-domain.sh --dry-run <ドメイン名>"
    exit 1
fi

# ─────────────────────────────────────────────
# 前提条件の確認
# ─────────────────────────────────────────────
[[ -f "$DOMAINS_FILE" ]]  || die "domains.yml が見つかりません: ${DOMAINS_FILE}"
[[ -d "$TEMPLATES_DIR" ]] || die "templates/ ディレクトリが見つかりません: ${TEMPLATES_DIR}"
command -v yq    &>/dev/null || die "yq がインストールされていません。先に setup.sh を実行してください。"
command -v nginx &>/dev/null || die "nginx がインストールされていません。先に setup.sh を実行してください。"

# ─────────────────────────────────────────────
# ドメイン設定のバリデーション関数
# ─────────────────────────────────────────────
validate_domain_config() {
    local domain="$1"

    # domains.yml にドメインが存在するか
    local exists
    exists=$(yq e ".domains[] | select(.name == \"${domain}\") | .name" "$DOMAINS_FILE")
    [[ -n "$exists" ]] || die "domains.yml に '${domain}' が見つかりません。"

    local type php_version port pm2_name
    type=$(yq e ".domains[] | select(.name == \"${domain}\") | .type" "$DOMAINS_FILE")
    [[ -n "$type" && "$type" != "null" ]] || die "[${domain}] type が未指定です。\"php\" または \"nodejs\" を設定してください。"
    [[ "$type" == "php" || "$type" == "nodejs" ]] || die "[${domain}] type は \"php\" または \"nodejs\" のみ有効です。(指定値: ${type})"

    if [[ "$type" == "php" ]]; then
        php_version=$(yq e ".domains[] | select(.name == \"${domain}\") | .php_version" "$DOMAINS_FILE")
        [[ -n "$php_version" && "$php_version" != "null" ]] || die "[${domain}] type: php のとき php_version は必須です。"

        local socket="/run/php/php${php_version}-fpm.sock"
        if [[ "$DRY_RUN" == false ]]; then
            # FPM が実際に起動しているか確認
            if ! systemctl is-active --quiet "php${php_version}-fpm"; then
                die "[${domain}] PHP ${php_version}-FPM が起動していません。\n  インストール: apt install php${php_version}-fpm && systemctl start php${php_version}-fpm"
            fi
        fi
    fi

    if [[ "$type" == "nodejs" ]]; then
        port=$(yq e ".domains[] | select(.name == \"${domain}\") | .port" "$DOMAINS_FILE")
        pm2_name=$(yq e ".domains[] | select(.name == \"${domain}\") | .pm2_name" "$DOMAINS_FILE")
        [[ -n "$port" && "$port" != "null" ]] || die "[${domain}] type: nodejs のとき port は必須です。"
        [[ -n "$pm2_name" && "$pm2_name" != "null" ]] || die "[${domain}] type: nodejs のとき pm2_name は必須です。"
        [[ "$port" =~ ^[0-9]+$ ]] || die "[${domain}] port は数値で指定してください。(指定値: ${port})"
        [[ "$port" -ge 1024 && "$port" -le 65535 ]] || die "[${domain}] port は 1024〜65535 の範囲で指定してください。"

        # ポートが他のプロセスで使われていないか確認 (同じ pm2_name のプロセスは除く)
        if [[ "$DRY_RUN" == false ]]; then
            local port_in_use
            port_in_use=$(ss -tlnp 2>/dev/null | grep ":${port} " || true)
            if [[ -n "$port_in_use" ]]; then
                warn "[${domain}] ポート ${port} は既に使用中の可能性があります:"
                echo "$port_in_use"
                warn "同じアプリを再設定する場合は無視して構いません。"
            fi
        fi
    fi

    # DNS 解決確認 (警告のみ)
    if ! host "$domain" &>/dev/null 2>&1; then
        warn "[${domain}] DNS が解決できません。Let's Encrypt の証明書取得前に DNS を設定してください。"
    fi

    success "[${domain}] バリデーション OK (type=${type})"
}

# ─────────────────────────────────────────────
# Nginx 設定ファイルの生成関数
# ─────────────────────────────────────────────
generate_nginx_config() {
    local domain="$1"

    local type php_version port ssl www_redirect
    type=$(yq e ".domains[] | select(.name == \"${domain}\") | .type" "$DOMAINS_FILE")
    ssl=$(yq e ".domains[] | select(.name == \"${domain}\") | .ssl" "$DOMAINS_FILE")
    www_redirect=$(yq e ".domains[] | select(.name == \"${domain}\") | .www_redirect" "$DOMAINS_FILE")

    local www_alias=""
    if [[ "$www_redirect" == "true" ]]; then
        www_alias=" www.${domain}"
    fi

    local config_file="/etc/nginx/sites-available/${domain}"
    local tmpl_file

    if [[ "$type" == "php" ]]; then
        php_version=$(yq e ".domains[] | select(.name == \"${domain}\") | .php_version" "$DOMAINS_FILE")
        tmpl_file="${TEMPLATES_DIR}/nginx-php.conf.tmpl"

        sed \
            -e "s|{{DOMAIN}}|${domain}|g" \
            -e "s|{{WWW_ALIAS}}|${www_alias}|g" \
            -e "s|{{PHP_VERSION}}|${php_version}|g" \
            "$tmpl_file"

    elif [[ "$type" == "nodejs" ]]; then
        port=$(yq e ".domains[] | select(.name == \"${domain}\") | .port" "$DOMAINS_FILE")
        tmpl_file="${TEMPLATES_DIR}/nginx-nodejs.conf.tmpl"

        sed \
            -e "s|{{DOMAIN}}|${domain}|g" \
            -e "s|{{WWW_ALIAS}}|${www_alias}|g" \
            -e "s|{{PORT}}|${port}|g" \
            "$tmpl_file"
    fi
}

# ─────────────────────────────────────────────
# ドメイン設定の適用関数
# ─────────────────────────────────────────────
apply_domain() {
    local domain="$1"
    info "=== ${domain} の設定を開始 ==="

    # バリデーション
    validate_domain_config "$domain"

    local type ssl www_redirect
    type=$(yq e ".domains[] | select(.name == \"${domain}\") | .type" "$DOMAINS_FILE")
    ssl=$(yq e ".domains[] | select(.name == \"${domain}\") | .ssl" "$DOMAINS_FILE")
    www_redirect=$(yq e ".domains[] | select(.name == \"${domain}\") | .www_redirect" "$DOMAINS_FILE")

    # ドキュメントルートの作成
    local webroot
    if [[ "$type" == "php" ]]; then
        webroot="/var/www/${domain}/public"
    else
        webroot="/var/www/${domain}"
    fi

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$webroot"
        chown -R www-data:www-data "/var/www/${domain}"
        info "ドキュメントルートを作成: ${webroot}"
    else
        info "[DRY-RUN] ドキュメントルートを作成予定: ${webroot}"
    fi

    # Nginx 設定ファイルの生成
    local config_file="/etc/nginx/sites-available/${domain}"
    local nginx_config
    nginx_config=$(generate_nginx_config "$domain")

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] 生成される Nginx 設定 (${config_file}):"
        echo "---"
        echo "$nginx_config"
        echo "---"
        success "[DRY-RUN] ${domain} のバリデーション・設定生成完了"
        return 0
    fi

    # 設定ファイルの書き込み
    echo "$nginx_config" > "$config_file"
    info "Nginx 設定を生成: ${config_file}"

    # nginx -t でシンタックスチェック (失敗時はロールバック)
    if ! nginx -t &>/dev/null; then
        error "Nginx 設定のシンタックスエラーが発生しました。設定を削除してロールバックします。"
        rm -f "$config_file"
        die "nginx -t に失敗しました。テンプレートを確認してください。"
    fi

    # sites-enabled へのシンボリックリンク
    ln -sf "$config_file" "/etc/nginx/sites-enabled/${domain}"
    info "sites-enabled にリンクを作成しました。"

    # Nginx リロード
    systemctl reload nginx
    success "Nginx をリロードしました。"

    # SSL 証明書の取得
    if [[ "$ssl" == "true" ]]; then
        local certbot_args=("--nginx" "-d" "$domain" "--non-interactive" "--agree-tos" "--email" "admin@${domain}")
        if [[ "$www_redirect" == "true" ]]; then
            certbot_args+=("-d" "www.${domain}")
        fi

        info "Let's Encrypt 証明書を取得中 (${domain})..."
        warn "※ テスト時は --staging フラグを追加することをお勧めします (レート制限回避のため)"
        certbot "${certbot_args[@]}" && success "SSL 証明書の取得完了" || warn "SSL 証明書の取得に失敗しました。DNS 設定を確認してください。"
    fi

    success "=== ${domain} の設定が完了しました ==="
    echo ""
}

# ─────────────────────────────────────────────
# メイン処理
# ─────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
    info "=== DRY-RUN モード (変更は行いません) ==="
fi

if [[ "$ADD_ALL" == true ]]; then
    info "domains.yml の全ドメインを処理します..."
    ALL_DOMAINS=$(yq e '.domains[].name' "$DOMAINS_FILE")
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        apply_domain "$domain"
    done <<< "$ALL_DOMAINS"
    success "全ドメインの設定が完了しました。"
else
    apply_domain "$TARGET_DOMAIN"
fi
