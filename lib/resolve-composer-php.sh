#!/usr/bin/env bash
# resolve-composer-php.sh — カレントディレクトリから Composer 用 PHP CLI を決める
# shellcheck shell=bash

COBACO_CONFIG_DIR="${COBACO_CONFIG_DIR:-/root/cobaco_config}"
DOMAINS_FILE="${DOMAINS_FILE:-${COBACO_CONFIG_DIR}/domains.yml}"
COMPOSER_PATHS_FILE="${COMPOSER_PATHS_FILE:-${COBACO_CONFIG_DIR}/composer-paths.yml}"

_resolve_longest_prefix_php() {
    local dir="$1"
    local best_len=0 best_ver=""
    local path ver name type

    if [[ -f "$COMPOSER_PATHS_FILE" ]] && command -v yq &>/dev/null; then
        while IFS=$'\t' read -r path ver; do
            [[ -n "$path" && "$path" != "null" ]] || continue
            case "$dir" in
                "$path" | "$path"/*)
                    if ((${#path} > best_len)); then
                        best_len=${#path}
                        best_ver="$ver"
                    fi
                    ;;
            esac
        done < <(yq -r '.paths[]? | [.path, .php_version] | @tsv' "$COMPOSER_PATHS_FILE" 2>/dev/null || true)
    fi

    if [[ -f "$DOMAINS_FILE" ]] && command -v yq &>/dev/null; then
        while IFS=$'\t' read -r name ver type; do
            [[ "$type" == "php" && -n "$name" && "$name" != "null" ]] || continue
            path="/var/www/${name}"
            case "$dir" in
                "$path" | "$path"/*)
                    if ((${#path} > best_len)); then
                        best_len=${#path}
                        best_ver="$ver"
                    fi
                    ;;
            esac
        done < <(yq -r '.domains[]? | [.name, .php_version, .type] | @tsv' "$DOMAINS_FILE" 2>/dev/null || true)
    fi

    [[ -n "$best_ver" && "$best_ver" != "null" ]] && printf '%s' "$best_ver"
}

resolve_composer_php_version() {
    local dir="${1:-.}"
    dir=$(cd "$dir" && pwd)

    local d="$dir" version=""
    while [[ "$d" != "/" ]]; do
        if [[ -f "$d/.php-version" ]]; then
            version=$(tr -d '[:space:]' < "$d/.php-version")
            break
        fi
        d=$(dirname "$d")
    done

    if [[ -z "$version" ]]; then
        version=$(_resolve_longest_prefix_php "$dir")
    fi

    printf '%s' "$version"
}

resolve_composer_php_cli() {
    local dir="${1:-.}"
    local version
    version=$(resolve_composer_php_version "$dir")

    local bin
    if [[ -n "$version" ]]; then
        bin="php${version}"
        if command -v "$bin" &>/dev/null; then
            command -v "$bin"
            return 0
        fi
        echo "resolve-composer-php: php${version} が見つかりません。デフォルト php を使います。" >&2
    fi

    command -v php
}

cobaco_composer() {
    local composer_phar php_cli
    composer_phar="${COBACO_COMPOSER_PHAR:-/usr/local/lib/cobaco/composer.phar}"

    if [[ ! -f "$composer_phar" ]]; then
        echo "cobaco_composer: Composer が見つかりません: ${composer_phar}" >&2
        echo "  root で bash install-composer.sh を実行してください。" >&2
        return 127
    fi

    php_cli=$(resolve_composer_php_cli "${COBACO_COMPOSER_CWD:-$PWD}")
    "$php_cli" "$composer_phar" "$@"
}
