#!/usr/bin/env bash
# install-composer.sh — Composer phar と cobaco ランチャーを配置 (root)
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

echo "OK: ${COMPOSER_BIN} (cobaco ランチャー)"
echo "    phar: ${COMPOSER_PHAR}"
echo ""
echo "次のステップ:"
echo "  1. 必要なら composer-paths.yml.sample を /root/cobaco_config/composer-paths.yml にコピー"
echo "  2. cobaco ユーザーで: cd /path/to/project && composer --version"
echo "  3. プロジェクト直下に .php-version (例: 8.5) を置く方法も使えます"
