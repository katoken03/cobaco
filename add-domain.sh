#!/usr/bin/env bash
# add-domain.sh - ドメイン追加・Nginx 設定生成スクリプト
# 使い方:
#   bash add-domain.sh example.com        # 単一ドメインを設定 (root)
#   bash add-domain.sh --all              # domains.yml の全ドメインを一括設定
#   bash add-domain.sh --dry-run example.com  # 変更せず検証のみ実行

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
    die "このスクリプトは root で実行してください。"
fi

# スクリプト自身のディレクトリ
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COBACO_SYSTEM_DOMAINS="/root/cobaco_config/domains.yml"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

resolve_domains_file() {
    local local_file="${SCRIPT_DIR}/domains.yml"
    if [[ -f "$COBACO_SYSTEM_DOMAINS" ]]; then
        DOMAINS_FILE="$COBACO_SYSTEM_DOMAINS"
        if [[ -f "$local_file" ]]; then
            warn "リポジトリ直下の domains.yml は無視します。使用中: ${COBACO_SYSTEM_DOMAINS}"
        fi
    elif [[ -f "$local_file" ]]; then
        DOMAINS_FILE="$local_file"
    else
        die "domains.yml が見つかりません。次のいずれかに配置してください:
  ${COBACO_SYSTEM_DOMAINS}
  ${local_file}
domains.yml.sample をコピーして編集してください。"
    fi
}

resolve_domains_file
HTPASSWD_DIR="/etc/nginx/htpasswd"

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
    echo "  bash add-domain.sh <ドメイン名>  (root)"
    echo "  bash add-domain.sh --all"
    echo "  bash add-domain.sh --dry-run <ドメイン名>"
    exit 1
fi

# ─────────────────────────────────────────────
# 前提条件の確認
# ─────────────────────────────────────────────
[[ -d "$TEMPLATES_DIR" ]] || die "templates/ ディレクトリが見つかりません: ${TEMPLATES_DIR}"
command -v yq    &>/dev/null || die "yq がインストールされていません。先に setup.sh を実行してください。"
command -v nginx &>/dev/null || die "nginx がインストールされていません。先に setup.sh を実行してください。"

# ─────────────────────────────────────────────
# ベーシック認証ヘルパー
# ─────────────────────────────────────────────
basic_auth_enabled() {
    local domain="$1"
    local title
    title=$(yq e ".domains[] | select(.name == \"${domain}\") | .basic_auth.title" "$DOMAINS_FILE")
    [[ -n "$title" && "$title" != "null" ]]
}

escape_nginx_auth_basic_title() {
    local title="$1"
    title="${title//\\/\\\\}"
    title="${title//\"/\\\"}"
    printf '%s' "$title"
}

generate_basic_auth_nginx_block() {
    local domain="$1"

    if ! basic_auth_enabled "$domain"; then
        return 0
    fi

    local title escaped_title htpasswd_file
    title=$(yq e ".domains[] | select(.name == \"${domain}\") | .basic_auth.title" "$DOMAINS_FILE")
    escaped_title=$(escape_nginx_auth_basic_title "$title")
    htpasswd_file="${HTPASSWD_DIR}/${domain}"

    printf '    auth_basic "%s";\n    auth_basic_user_file %s;\n' "$escaped_title" "$htpasswd_file"
}

validate_basic_auth_config() {
    local domain="$1"

    local basic_auth_node
    basic_auth_node=$(yq e ".domains[] | select(.name == \"${domain}\") | .basic_auth" "$DOMAINS_FILE")
    if [[ "$basic_auth_node" == "null" ]]; then
        return 0
    fi

    local title count dup id password i
    title=$(yq e ".domains[] | select(.name == \"${domain}\") | .basic_auth.title" "$DOMAINS_FILE")
    [[ -n "$title" && "$title" != "null" ]] || die "[${domain}] basic_auth を使う場合 basic_auth.title は必須です。"
    [[ "$title" != *$'\n'* ]] || die "[${domain}] basic_auth.title に改行は使えません。"

    count=$(yq e ".domains[] | select(.name == \"${domain}\") | .basic_auth.users | length" "$DOMAINS_FILE")
    [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || die "[${domain}] basic_auth.users は 1 人以上指定してください。"

    dup=$(yq -r ".domains[] | select(.name == \"${domain}\") | .basic_auth.users[].id" "$DOMAINS_FILE" | sort | uniq -d)
    [[ -z "$dup" ]] || die "[${domain}] basic_auth.users の id が重複しています: ${dup}"

    for ((i = 0; i < count; i++)); do
        id=$(yq -r ".domains[] | select(.name == \"${domain}\") | .basic_auth.users[${i}].id" "$DOMAINS_FILE")
        password=$(yq -r ".domains[] | select(.name == \"${domain}\") | .basic_auth.users[${i}].password" "$DOMAINS_FILE")

        [[ -n "$id" && "$id" != "null" ]] || die "[${domain}] basic_auth.users[${i}].id は必須です。"
        [[ "$id" =~ ^[A-Za-z0-9._@+-]+$ ]] || die "[${domain}] basic_auth.users[${i}].id の形式が不正です。(指定値: ${id})"

        [[ -n "$password" && "$password" != "null" ]] || die "[${domain}] basic_auth.users[${i}].password は必須です。"
        [[ "$password" != *$'\n'* ]] || die "[${domain}] basic_auth.users[${i}].password に改行は使えません。"
    done

    if [[ "$DRY_RUN" == false ]]; then
        command -v htpasswd &>/dev/null || die "[${domain}] htpasswd が見つかりません。apt install apache2-utils を実行してください。"
    fi
}

htpasswd_matches_declaration() {
    local domain="$1"
    local htpasswd_file="$2"
    local count i id password declared existing

    count=$(yq e ".domains[] | select(.name == \"${domain}\") | .basic_auth.users | length" "$DOMAINS_FILE")
    declared=$(yq -r ".domains[] | select(.name == \"${domain}\") | .basic_auth.users[].id" "$DOMAINS_FILE" | sort)
    existing=$(cut -d: -f1 "$htpasswd_file" | sort)
    [[ "$declared" == "$existing" ]] || return 1

    for ((i = 0; i < count; i++)); do
        id=$(yq -r ".domains[] | select(.name == \"${domain}\") | .basic_auth.users[${i}].id" "$DOMAINS_FILE")
        password=$(yq -r ".domains[] | select(.name == \"${domain}\") | .basic_auth.users[${i}].password" "$DOMAINS_FILE")
        if ! printf '%s' "$password" | htpasswd -v -i "$htpasswd_file" "$id" &>/dev/null; then
            return 1
        fi
    done

    return 0
}

ensure_htpasswd_permissions() {
    local htpasswd_file="$1"
    local owner mode

    owner=$(stat -c '%U:%G' "$htpasswd_file")
    mode=$(stat -c '%a' "$htpasswd_file")

    if [[ "$owner" != "root:www-data" ]]; then
        chown root:www-data "$htpasswd_file"
    fi
    if [[ "$mode" != "640" ]]; then
        chmod 640 "$htpasswd_file"
    fi
}

sync_basic_auth_htpasswd() {
    local domain="$1"
    local htpasswd_file="${HTPASSWD_DIR}/${domain}"

    if ! basic_auth_enabled "$domain"; then
        if [[ -f "$htpasswd_file" ]]; then
            rm -f "$htpasswd_file"
            info "ベーシック認証ファイルを削除: ${htpasswd_file}"
        fi
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    mkdir -p "$HTPASSWD_DIR"

    local count i id password tmp needs_update=false
    count=$(yq e ".domains[] | select(.name == \"${domain}\") | .basic_auth.users | length" "$DOMAINS_FILE")

    if [[ ! -f "$htpasswd_file" ]] || ! htpasswd_matches_declaration "$domain" "$htpasswd_file"; then
        needs_update=true
    fi

    if [[ "$needs_update" == true ]]; then
        tmp=$(mktemp "${HTPASSWD_DIR}/.${domain}.XXXXXX")
        rm -f "$tmp"

        for ((i = 0; i < count; i++)); do
            id=$(yq -r ".domains[] | select(.name == \"${domain}\") | .basic_auth.users[${i}].id" "$DOMAINS_FILE")
            password=$(yq -r ".domains[] | select(.name == \"${domain}\") | .basic_auth.users[${i}].password" "$DOMAINS_FILE")
            if [[ "$i" -eq 0 ]]; then
                printf '%s' "$password" | htpasswd -B -c -i "$tmp" "$id"
            else
                printf '%s' "$password" | htpasswd -B -i "$tmp" "$id"
            fi
        done

        mv "$tmp" "$htpasswd_file"
        chown root:www-data "$htpasswd_file"
        chmod 640 "$htpasswd_file"
        info "ベーシック認証ファイルを更新: ${htpasswd_file}"
    else
        ensure_htpasswd_permissions "$htpasswd_file"
    fi
}

render_nginx_template() {
    local domain="$1"
    local rendered="$2"
    local basic_auth_block line

    basic_auth_block=$(generate_basic_auth_nginx_block "$domain")

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "{{BASIC_AUTH}}" ]]; then
            if [[ -n "$basic_auth_block" ]]; then
                printf '%s\n' "$basic_auth_block"
            fi
        else
            printf '%s\n' "$line"
        fi
    done <<< "$rendered"
}

ssl_certificate_exists() {
    local domain="$1"
    [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]
}

ssl_subdomains_count() {
    local domain="$1"
    yq e ".domains[] | select(.name == \"${domain}\") | .ssl_subdomains | length" "$DOMAINS_FILE"
}

read_ssl_subdomains() {
    local domain="$1"
    yq -r ".domains[] | select(.name == \"${domain}\") | .ssl_subdomains[]?" "$DOMAINS_FILE" 2>/dev/null || true
}

validate_ssl_subdomains_config() {
    local domain="$1"
    local ssl www_redirect
    ssl=$(yq e ".domains[] | select(.name == \"${domain}\") | .ssl" "$DOMAINS_FILE")
    www_redirect=$(yq e ".domains[] | select(.name == \"${domain}\") | .www_redirect" "$DOMAINS_FILE")

    local count
    count=$(ssl_subdomains_count "$domain")
    if [[ "$count" == "null" || -z "$count" ]]; then
        count=0
    fi
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        die "[${domain}] ssl_subdomains の形式が不正です。文字列の配列で指定してください。"
    fi

    if [[ "$ssl" != "true" && "$count" -gt 0 ]]; then
        die "[${domain}] ssl_subdomains は ssl: true のときのみ指定できます。"
    fi

    if [[ "$count" -eq 0 ]]; then
        if [[ "$ssl" == "true" && "$www_redirect" == "true" ]]; then
            die "[${domain}] ssl: true かつ www_redirect: true のとき、ssl_subdomains に www.${domain} を追加してください。"
        fi
        return 0
    fi

    local dup other_names host suffix seen=() has_www=false
    suffix=".${domain}"
    other_names=$(yq -r '.domains[].name' "$DOMAINS_FILE" | grep -vxF "$domain" || true)

    while IFS= read -r host; do
        [[ -z "$host" || "$host" == "null" ]] && continue

        [[ "$host" == "$domain" ]] && die "[${domain}] ssl_subdomains に apex (${domain}) は指定できません。name に含まれます。"
        [[ "$host" == *"*"* ]] && die "[${domain}] ssl_subdomains にワイルドカードは使えません。(指定値: ${host})"
        [[ "$host" == *"${suffix}" ]] || die "[${domain}] ssl_subdomains の各要素は *.${domain} 形式の FQDN にしてください。(指定値: ${host})"

        if [[ "$host" == "www.${domain}" ]]; then
            has_www=true
        fi

        local s
        for s in "${seen[@]:-}"; do
            [[ "$s" == "$host" ]] && die "[${domain}] ssl_subdomains に重複があります: ${host}"
        done
        seen+=("$host")

        if echo "$other_names" | grep -qxF "$host"; then
            die "[${domain}] ssl_subdomains の ${host} は別エントリの name と衝突します。別サイトとして運用する場合は domains に別行で定義してください。"
        fi

        if ! host "$host" &>/dev/null 2>&1; then
            warn "[${domain}] ssl_subdomains の ${host} は DNS が解決できません。Let's Encrypt 取得前に DNS を設定してください。"
        fi
    done < <(read_ssl_subdomains "$domain")

    dup=$(read_ssl_subdomains "$domain" | sort | uniq -d)
    [[ -z "$dup" ]] || die "[${domain}] ssl_subdomains に重複があります: ${dup}"

    if [[ "$ssl" == "true" && "$www_redirect" == "true" && "$has_www" == false ]]; then
        die "[${domain}] ssl: true かつ www_redirect: true のとき、ssl_subdomains に www.${domain} を追加してください。"
    fi
}

build_server_aliases() {
    local domain="$1"
    local www_redirect
    www_redirect=$(yq e ".domains[] | select(.name == \"${domain}\") | .www_redirect" "$DOMAINS_FILE")

    local aliases=() host seen=()

    if [[ "$www_redirect" == "true" ]]; then
        aliases+=("www.${domain}")
        seen+=("www.${domain}")
    fi

    while IFS= read -r host; do
        [[ -z "$host" || "$host" == "null" ]] && continue
        local s found=false
        for s in "${seen[@]:-}"; do
            if [[ "$s" == "$host" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            aliases+=("$host")
            seen+=("$host")
        fi
    done < <(read_ssl_subdomains "$domain")

    local result=""
    for host in "${aliases[@]:-}"; do
        result+=" ${host}"
    done
    printf '%s' "$result"
}

build_ssl_certificate_names() {
    local domain="$1"
    local names=("$domain") host seen=("$domain")

    while IFS= read -r host; do
        [[ -z "$host" || "$host" == "null" ]] && continue
        local s found=false
        for s in "${seen[@]:-}"; do
            if [[ "$s" == "$host" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            names+=("$host")
            seen+=("$host")
        fi
    done < <(read_ssl_subdomains "$domain")

    printf '%s\n' "${names[@]}"
}

get_certificate_sans() {
    local domain="$1"
    local pem="/etc/letsencrypt/live/${domain}/fullchain.pem"
    [[ -f "$pem" ]] || return 0
    openssl x509 -in "$pem" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' \
        | sed -n 's/^[[:space:]]*DNS:\(.*\)/\1/p'
}

certificate_covers_all_names() {
    local domain="$1"
    local missing
    missing=$(certificate_missing_names "$domain")
    [[ -z "$missing" ]]
}

certificate_missing_names() {
    local domain="$1"
    local desired sans host
    desired=$(build_ssl_certificate_names "$domain")
    sans=$(get_certificate_sans "$domain")

    while IFS= read -r host; do
        [[ -z "$host" ]] && continue
        if ! echo "$sans" | grep -qxF "$host"; then
            echo "$host"
        fi
    done <<< "$desired"
}

warn_certificate_extra_sans() {
    local domain="$1"
    local desired sans host
    desired=$(build_ssl_certificate_names "$domain")
    sans=$(get_certificate_sans "$domain")

    while IFS= read -r host; do
        [[ -z "$host" ]] && continue
        if ! echo "$desired" | grep -qxF "$host"; then
            warn "[${domain}] 証明書に domains.yml に無い名前が含まれています: ${host}（自動では削除しません。更新は certbot.timer に任せます）"
        fi
    done <<< "$sans"
}

use_ssl_nginx_template() {
    local domain="$1"
    local ssl
    ssl=$(yq e ".domains[] | select(.name == \"${domain}\") | .ssl" "$DOMAINS_FILE")
    [[ "$ssl" == "true" ]] && ssl_certificate_exists "$domain"
}

write_and_reload_nginx_config() {
    local domain="$1"
    local config_file="/etc/nginx/sites-available/${domain}"
    local nginx_config

    nginx_config=$(generate_nginx_config "$domain")
    echo "$nginx_config" > "$config_file"
    info "Nginx 設定を生成: ${config_file}"

    if ! nginx -t &>/dev/null; then
        error "Nginx 設定のシンタックスエラーが発生しました。設定を削除してロールバックします。"
        rm -f "$config_file"
        die "nginx -t に失敗しました。テンプレートを確認してください。"
    fi

    ln -sf "$config_file" "/etc/nginx/sites-enabled/${domain}"
    info "sites-enabled にリンクを作成しました。"

    systemctl reload nginx
    success "Nginx をリロードしました。"
}

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

    validate_basic_auth_config "$domain"
    validate_ssl_subdomains_config "$domain"

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

    local type php_version port ssl
    type=$(yq e ".domains[] | select(.name == \"${domain}\") | .type" "$DOMAINS_FILE")
    ssl=$(yq e ".domains[] | select(.name == \"${domain}\") | .ssl" "$DOMAINS_FILE")

    local server_aliases
    server_aliases=$(build_server_aliases "$domain")

    local config_file="/etc/nginx/sites-available/${domain}"
    local tmpl_file

    local rendered=""

    if [[ "$type" == "php" ]]; then
        php_version=$(yq e ".domains[] | select(.name == \"${domain}\") | .php_version" "$DOMAINS_FILE")
        if use_ssl_nginx_template "$domain"; then
            tmpl_file="${TEMPLATES_DIR}/nginx-php-ssl.conf.tmpl"
        else
            tmpl_file="${TEMPLATES_DIR}/nginx-php.conf.tmpl"
        fi

        rendered=$(sed \
            -e "s|{{DOMAIN}}|${domain}|g" \
            -e "s|{{SERVER_ALIASES}}|${server_aliases}|g" \
            -e "s|{{PHP_VERSION}}|${php_version}|g" \
            "$tmpl_file")

    elif [[ "$type" == "nodejs" ]]; then
        port=$(yq e ".domains[] | select(.name == \"${domain}\") | .port" "$DOMAINS_FILE")
        if use_ssl_nginx_template "$domain"; then
            tmpl_file="${TEMPLATES_DIR}/nginx-nodejs-ssl.conf.tmpl"
        else
            tmpl_file="${TEMPLATES_DIR}/nginx-nodejs.conf.tmpl"
        fi

        rendered=$(sed \
            -e "s|{{DOMAIN}}|${domain}|g" \
            -e "s|{{SERVER_ALIASES}}|${server_aliases}|g" \
            -e "s|{{PORT}}|${port}|g" \
            "$tmpl_file")
    fi

    render_nginx_template "$domain" "$rendered"
}

# ─────────────────────────────────────────────
# ドメイン設定の適用関数
# ─────────────────────────────────────────────
apply_domain() {
    local domain="$1"
    info "=== ${domain} の設定を開始 ==="

    # バリデーション
    validate_domain_config "$domain"

    local type ssl
    type=$(yq e ".domains[] | select(.name == \"${domain}\") | .type" "$DOMAINS_FILE")
    ssl=$(yq e ".domains[] | select(.name == \"${domain}\") | .ssl" "$DOMAINS_FILE")

    # ドキュメントルートの作成
    local webroot
    if [[ "$type" == "php" ]]; then
        webroot="/var/www/${domain}/public"
    else
        webroot="/var/www/${domain}"
    fi

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$webroot"
        chown -R deploy:www-data "/var/www/${domain}"
        info "ドキュメントルートを作成: ${webroot}"
    else
        info "[DRY-RUN] ドキュメントルートを作成予定: ${webroot}"
    fi

    sync_basic_auth_htpasswd "$domain"

    if [[ "$DRY_RUN" == true ]] && basic_auth_enabled "$domain"; then
        local auth_title auth_ids
        auth_title=$(yq e ".domains[] | select(.name == \"${domain}\") | .basic_auth.title" "$DOMAINS_FILE")
        auth_ids=$(yq -r ".domains[] | select(.name == \"${domain}\") | .basic_auth.users[].id" "$DOMAINS_FILE" | paste -sd, -)
        info "[DRY-RUN] basic_auth title=\"${auth_title}\" users=${auth_ids} htpasswd=${HTPASSWD_DIR}/${domain}"
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

    write_and_reload_nginx_config "$domain"

    # SSL 証明書の取得（SAN が足りないときのみ certbot。揃っている場合は cobaco テンプレートで HTTPS を管理する）
    if [[ "$ssl" == "true" ]]; then
        local cert_host missing_names
        if ssl_certificate_exists "$domain"; then
            warn_certificate_extra_sans "$domain"
            if certificate_covers_all_names "$domain"; then
                info "SSL 証明書は希望する名前をすべて含んでいます。certbot --nginx はスキップします（Basic 認証等をテンプレートで維持）。"
            else
                missing_names=$(certificate_missing_names "$domain" | paste -sd, -)
                info "SSL 証明書に不足している名前があります (${missing_names})。certbot --expand を実行します..."
                local certbot_args=("--nginx" "--non-interactive" "--agree-tos" "--email" "admin@${domain}" "--cert-name" "$domain" "--expand")
                while IFS= read -r cert_host; do
                    [[ -z "$cert_host" ]] && continue
                    certbot_args+=("-d" "$cert_host")
                done < <(build_ssl_certificate_names "$domain")

                warn "※ テスト時は --staging フラグを追加することをお勧めします (レート制限回避のため)"
                if certbot "${certbot_args[@]}"; then
                    success "SSL 証明書の更新（expand）完了"
                    info "HTTPS 用 Nginx テンプレートを再適用します..."
                    write_and_reload_nginx_config "$domain"
                else
                    warn "SSL 証明書の更新に失敗しました。DNS 設定を確認してください。"
                fi
            fi
        else
            local certbot_args=("--nginx" "--non-interactive" "--agree-tos" "--email" "admin@${domain}")
            while IFS= read -r cert_host; do
                [[ -z "$cert_host" ]] && continue
                certbot_args+=("-d" "$cert_host")
            done < <(build_ssl_certificate_names "$domain")

            info "Let's Encrypt 証明書を取得中 (${domain})..."
            warn "※ テスト時は --staging フラグを追加することをお勧めします (レート制限回避のため)"
            if certbot "${certbot_args[@]}"; then
                success "SSL 証明書の取得完了"
                if ssl_certificate_exists "$domain"; then
                    info "HTTPS 用 Nginx テンプレートを再適用します..."
                    write_and_reload_nginx_config "$domain"
                fi
            else
                warn "SSL 証明書の取得に失敗しました。DNS 設定を確認してください。"
            fi
        fi
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
