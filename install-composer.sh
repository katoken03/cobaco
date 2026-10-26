#!/usr/bin/env bash
# install-composer.sh — Composer phar と CLI シム (composer / cobaco-php) を配置 (root)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "このスクリプトは root で実行してください。" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COBACO_LIB="/usr/local/lib/cobaco"
COMPOSER_PHAR="${COBACO_LIB}/composer.phar"
COMPOSER_BIN="/usr/local/bin/composer"

mkdir -p "$COBACO_LIB"

if [[ ! -f "$COMPOSER_PHAR" ]]; then
    echo "Composer phar を取得中..."
    curl -sS https://getcomposer.org/installer | php -- --install-dir="$COBACO_LIB" --filename=composer.phar
fi

install -m 644 "${SCRIPT_DIR}/lib/resolve-composer-php.sh" "${COBACO_LIB}/resolve-composer-php.sh"

if [[ -f "$COMPOSER_BIN" ]] && [[ $(head -1 "$COMPOSER_BIN") != *"cobaco Composer"* ]]; then
    if [[ ! -f "${COMPOSER_BIN}.pre-cobaco" ]]; then
        mv "$COMPOSER_BIN" "${COMPOSER_BIN}.pre-cobaco"
        echo "既存の ${COMPOSER_BIN} を ${COMPOSER_BIN}.pre-cobaco に退避しました。"
    fi
fi

install -m 755 "${SCRIPT_DIR}/bin/composer" "$COMPOSER_BIN"

COBACO_PHP_BIN="/usr/local/bin/cobaco-php"
install -m 755 "${SCRIPT_DIR}/bin/cobaco-php" "$COBACO_PHP_BIN"

if id cobaco &>/dev/null; then
    COBACO_HOME="/home/cobaco"
    mkdir -p "${COBACO_HOME}/bin"
    install -m 755 "${SCRIPT_DIR}/bin/cobaco-php" "${COBACO_HOME}/bin/php"
    chown cobaco:cobaco "${COBACO_HOME}/bin/php"

    COBACO_PROFILE="${COBACO_HOME}/.profile"
    if [[ ! -f "$COBACO_PROFILE" ]]; then
        touch "$COBACO_PROFILE"
        chown cobaco:cobaco "$COBACO_PROFILE"
    fi
    if ! grep -q 'cobaco: home bin PATH for project php shim' "$COBACO_PROFILE" 2>/dev/null; then
        printf '%s\n' '# cobaco: home bin PATH for project php shim' 'export PATH="$HOME/bin:$PATH"' >> "$COBACO_PROFILE"
        chown cobaco:cobaco "$COBACO_PROFILE"
    fi
else
    echo "WARN: cobaco ユーザーが未作成のため ~/bin/php と .profile の PATH はスキップしました。" >&2
fi

echo "OK: ${COMPOSER_BIN} (cobaco ランチャー)"
echo "OK: ${COBACO_PHP_BIN} (PHP CLI シム)"
echo "    phar: ${COMPOSER_PHAR}"
if id cobaco &>/dev/null; then
    echo "OK: /home/cobaco/bin/php (cobaco ユーザー用。~/.profile で PATH 優先)"
fi
echo ""
echo "次のステップ:"
echo "  1. 必要なら composer-paths.yml.sample を /root/cobaco_config/composer-paths.yml にコピー"
echo "  2. cobaco ユーザーで: cd /path/to/project && composer --version && php -v"
echo "  3. プロジェクト直下に .php-version (例: 8.5) を置く方法も使えます"
