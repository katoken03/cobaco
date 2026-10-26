#!/usr/bin/env bash
# apply-mysql.sh - domains.yml の mysql 宣言を MariaDB に適用
# 使い方:
#   bash apply-mysql.sh example.com
#   bash apply-mysql.sh --all
#   bash apply-mysql.sh --dry-run example.com

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
COBACO_SYSTEM_DOMAINS="/root/cobaco_config/domains.yml"

resolve_domains_file() {
    if [[ -f "$COBACO_SYSTEM_DOMAINS" ]]; then
        DOMAINS_FILE="$COBACO_SYSTEM_DOMAINS"
    else
        die "domains.yml が見つかりません: ${COBACO_SYSTEM_DOMAINS}
domains.yml.sample をコピーして編集してください。"
    fi
}

resolve_domains_file

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
    echo "  bash apply-mysql.sh <ドメイン名>  (root)"
    echo "  bash apply-mysql.sh --all"
    echo "  bash apply-mysql.sh --dry-run <ドメイン名>"
    exit 1
fi

command -v yq &>/dev/null || die "yq がインストールされていません。先に setup.sh を実行してください。"

DEFAULT_CHARSET="utf8mb4"
DEFAULT_COLLATION="utf8mb4_unicode_ci"
MYSQL_NAME_PATTERN='^[A-Za-z][A-Za-z0-9_]*$'

mysql_escape_string_literal() {
    local s="$1"
    s="${s//\'/\'\'}"
    printf '%s' "$s"
}

quote_mysql_identifier() {
    local id="$1"
    id="${id//\`/\`\`}"
    printf '`%s`' "$id"
}

validate_mysql_identifier() {
    local label="$1"
    local value="$2"
    local context="$3"

    [[ -n "$value" && "$value" != "null" ]] || die "${context} ${label} は必須です。"
    [[ ${#value} -le 64 ]] || die "${context} ${label} は 64 文字以内にしてください。(指定値: ${value})"
    [[ "$value" =~ $MYSQL_NAME_PATTERN ]] || die "${context} ${label} の形式が不正です。(指定値: ${value})"
}

domain_mysql_configured() {
    local domain="$1"
    local node
    node=$(yq e ".domains[] | select(.name == \"${domain}\") | .mysql" "$DOMAINS_FILE")
    [[ "$node" != "null" ]]
}

domain_mysql_entry_count() {
    local domain="$1"
    yq e ".domains[] | select(.name == \"${domain}\") | .mysql | length" "$DOMAINS_FILE"
}

validate_mysql_globals() {
    local dup_db dup_user
    dup_db=$(yq -r '.domains[] | .mysql[]? | .database' "$DOMAINS_FILE" | sort | uniq -d)
    [[ -z "$dup_db" ]] || die "mysql.database が domains.yml 内で重複しています: ${dup_db}"

    dup_user=$(yq -r '.domains[] | .mysql[]? | .user' "$DOMAINS_FILE" | sort | uniq -d)
    [[ -z "$dup_user" ]] || die "mysql.user が domains.yml 内で重複しています: ${dup_user}"
}

validate_domain_mysql() {
    local domain="$1"

    if ! domain_mysql_configured "$domain"; then
        return 0
    fi

    local count i database user password charset collation
    count=$(domain_mysql_entry_count "$domain")
    [[ "$count" =~ ^[0-9]+$ ]] || die "[${domain}] mysql は配列で指定してください。"

    for ((i = 0; i < count; i++)); do
        database=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${i}].database" "$DOMAINS_FILE")
        user=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${i}].user" "$DOMAINS_FILE")
        password=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${i}].password" "$DOMAINS_FILE")
        charset=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${i}].charset // \"${DEFAULT_CHARSET}\"" "$DOMAINS_FILE")
        collation=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${i}].collation // \"${DEFAULT_COLLATION}\"" "$DOMAINS_FILE")

        local ctx="[${domain}] mysql[${i}]"
        validate_mysql_identifier "database" "$database" "$ctx"
        validate_mysql_identifier "user" "$user" "$ctx"
        validate_mysql_identifier "charset" "$charset" "$ctx"
        validate_mysql_identifier "collation" "$collation" "$ctx"

        [[ -n "$password" && "$password" != "null" ]] || die "${ctx} password は必須です。"
        [[ "$password" != *$'\n'* ]] || die "${ctx} password に改行は使えません。"
    done
}

ensure_mariadb_admin() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    command -v mysql &>/dev/null || die "mysql クライアントが見つかりません。MariaDB をインストールしてください。"

    if ! systemctl is-active --quiet mariadb 2>/dev/null; then
        die "MariaDB (mariadb) が起動していません。systemctl start mariadb を実行してください。"
    fi

    if ! mysql -u root -e "SELECT 1;" &>/dev/null; then
        die "root で MariaDB に接続できません。unix_socket 認証か /root/.my.cnf を確認してください。"
    fi
}

warn_charset_mismatch() {
    local domain="$1"
    local database="$2"
    local want_charset="$3"
    local want_collation="$4"

    [[ "$DRY_RUN" == true ]] && return 0

    local row have_charset have_collation
    row=$(mysql -N -u root -e \
        "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(mysql_escape_string_literal "$database")';" \
        2>/dev/null || true)

    [[ -n "$row" ]] || return 0

    have_charset=$(printf '%s' "$row" | awk '{print $1}')
    have_collation=$(printf '%s' "$row" | awk '{print $2}')

    if [[ "$have_charset" != "$want_charset" || "$have_collation" != "$want_collation" ]]; then
        warn "[${domain}] 既存 DB ${database} の文字セット (${have_charset}/${have_collation}) が宣言 (${want_charset}/${want_collation}) と異なります。変更は行いません。"
    fi
}

apply_mysql_entry() {
    local domain="$1"
    local index="$2"

    local database user password charset collation
    database=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${index}].database" "$DOMAINS_FILE")
    user=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${index}].user" "$DOMAINS_FILE")
    password=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${index}].password" "$DOMAINS_FILE")
    charset=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${index}].charset // \"${DEFAULT_CHARSET}\"" "$DOMAINS_FILE")
    collation=$(yq -r ".domains[] | select(.name == \"${domain}\") | .mysql[${index}].collation // \"${DEFAULT_COLLATION}\"" "$DOMAINS_FILE")

    local db_ident pass_escaped sql
    db_ident=$(quote_mysql_identifier "$database")
    pass_escaped=$(mysql_escape_string_literal "$password")

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] [${domain}] mysql: database=${database} user=${user}@localhost charset=${charset} collation=${collation}"
        return 0
    fi

    warn_charset_mismatch "$domain" "$database" "$charset" "$collation"

    sql=$(cat <<EOF
CREATE DATABASE IF NOT EXISTS ${db_ident}
  CHARACTER SET ${charset}
  COLLATE ${collation};
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass_escaped}';
ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pass_escaped}';
GRANT ALL PRIVILEGES ON ${db_ident}.* TO '${user}'@'localhost';
FLUSH PRIVILEGES;
EOF
)

    if mysql -u root <<EOF
${sql}
EOF
    then
        success "[${domain}] MariaDB: ${database} / ${user}@localhost"
    else
        die "[${domain}] MariaDB への適用に失敗しました (database=${database}, user=${user})"
    fi
}

apply_domain_mysql() {
    local domain="$1"

    local exists
    exists=$(yq e ".domains[] | select(.name == \"${domain}\") | .name" "$DOMAINS_FILE")
    [[ -n "$exists" ]] || die "domains.yml に '${domain}' が見つかりません。"

    validate_domain_mysql "$domain"

    if ! domain_mysql_configured "$domain"; then
        info "[${domain}] mysql 宣言なし — スキップ"
        return 0
    fi

    local count i
    count=$(domain_mysql_entry_count "$domain")
    if [[ "$count" -eq 0 ]]; then
        info "[${domain}] mysql 宣言なし — スキップ"
        return 0
    fi

    ensure_mariadb_admin

    info "[${domain}] mysql 宣言 ${count} 件を適用します..."
    for ((i = 0; i < count; i++)); do
        apply_mysql_entry "$domain" "$i"
    done
}

validate_mysql_globals

if [[ "$DRY_RUN" == true ]]; then
    info "=== DRY-RUN モード (MariaDB には変更しません) ==="
fi

if [[ "$ADD_ALL" == true ]]; then
    ALL_DOMAINS=$(yq e '.domains[].name' "$DOMAINS_FILE")
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        apply_domain_mysql "$domain"
    done <<< "$ALL_DOMAINS"
    success "全ドメインの mysql 適用が完了しました。"
else
    apply_domain_mysql "$TARGET_DOMAIN"
fi
