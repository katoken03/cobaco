#!/usr/bin/env bash
# ssh-allow.sh — SSH 接続元の許可リスト (ssh-allow.list) と UFW / fail2ban ignoreip を同期する
# configure-firewall.sh と bin/ssh-allow が source する。info / success / warn / error は呼び出し側で定義する。
# shellcheck shell=bash

COBACO_CONFIG_DIR="${COBACO_CONFIG_DIR:-/root/cobaco_config}"
SSH_ALLOW_LIST="${SSH_ALLOW_LIST:-${COBACO_CONFIG_DIR}/ssh-allow.list}"
# ssh-allow off で退避したリスト。これがあれば「意図して SSH を全体に公開中」とみなす
SSH_ALLOW_DISABLED="${SSH_ALLOW_DISABLED:-${SSH_ALLOW_LIST}.disabled}"
SSH_ALLOW_F2B_FILE="${SSH_ALLOW_F2B_FILE:-/etc/fail2ban/jail.d/cobaco-ignoreip.local}"
SSH_ALLOW_UFW_DIR="${SSH_ALLOW_UFW_DIR:-/etc/ufw}"

# ssh.socket の ListenStream からポートを出力する (なければ 22)
# 空の ListenStream= はそれまでの指定を打ち消す (systemd の drop-in の書き方)
ssh_allow_listen_ports() {
    local ports=()
    mapfile -t ports < <(
        systemctl cat ssh.socket 2>/dev/null | awk '
            /^ListenStream=/ {
                line = $0
                sub(/^ListenStream=/, "", line)
                if (line == "") { split("", found); next }
                if (line == "-") next
                n = split(line, a, ":")
                found[a[n]] = 1
            }
            END { for (p in found) print p }
        ' | sort -nu
    )
    if ((${#ports[@]} == 0)); then
        ports=(22)
    fi
    printf '%s\n' "${ports[@]}"
}

# 引数の IP / CIDR を正規化して出力する (単一ホストは /32 /128 を付けない)。不正なら何も出さず 1 を返す
ssh_allow_normalize() {
    python3 -I -c '
import ipaddress, sys
ok = True
for arg in sys.argv[1:]:
    try:
        net = ipaddress.ip_network(arg, strict=False)
    except ValueError:
        ok = False
        continue
    if net.prefixlen == 0:
        ok = False
        continue
    print(net.network_address if net.prefixlen == net.max_prefixlen else net)
sys.exit(0 if ok else 1)
' "$@"
}

# 許可リスト (引数でファイル指定可。既定は有効なリスト) を「アドレス<TAB>メモ」で出力する
ssh_allow_read_list() {
    local file="${1:-$SSH_ALLOW_LIST}"
    [[ -f "$file" ]] || return 0
    awk '
        { sub(/#.*/, "") }
        NF == 0 { next }
        {
            addr = $1
            $1 = ""
            sub(/^[ \t]+/, "")
            print addr "\t" $0
        }
    ' "$file"
}

# 絞り込みの状態: on (許可リストに 1 件以上) / off (ssh-allow off 済み) / unset (未設定)
ssh_allow_state() {
    if [[ -n "$(ssh_allow_read_list)" ]]; then
        echo on
    elif [[ -f "$SSH_ALLOW_DISABLED" ]]; then
        echo off
    else
        echo unset
    fi
}

# UFW に登録済みの SSH ポート宛て allow ルールを「ポート<TAB>proto<TAB>送信元<TAB>アプリ名」で出力する
# 送信元が全体 (0.0.0.0/0, ::/0) のものは "any" と出す
ssh_allow_ufw_rules() {
    local ports_csv
    ports_csv="$(ssh_allow_listen_ports | paste -sd, -)"
    cat "${SSH_ALLOW_UFW_DIR}/user.rules" "${SSH_ALLOW_UFW_DIR}/user6.rules" 2>/dev/null | awk -v ports="$ports_csv" '
        BEGIN { n = split(ports, p, ","); for (i = 1; i <= n; i++) want[p[i]] = 1 }
        $1 == "###" && $2 == "tuple" && $4 == "allow" {
            dport = $6; src = $9
            app = ($10 != "in" && $10 != "out") ? $10 : "-"
            if (app == "OpenSSH") dport = "22"
            if (!(dport in want)) next
            if (src == "0.0.0.0/0" || src == "::/0") src = "any"
            print dport "\t" $5 "\t" src "\t" app
        }
    ' | sort -u
}

# fail2ban の ignoreip を許可リストに合わせる
_ssh_allow_sync_fail2ban() {
    command -v fail2ban-client &>/dev/null || return 0
    local addrs
    addrs="$(ssh_allow_read_list | cut -f1 | paste -sd' ' -)"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# cobaco: ssh-allow が生成。手で編集しない
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${addrs}
EOF
    if [[ -f "$SSH_ALLOW_F2B_FILE" ]] && cmp -s "$tmp" "$SSH_ALLOW_F2B_FILE"; then
        rm -f "$tmp"
        return 0
    fi
    local backup=""
    if [[ -f "$SSH_ALLOW_F2B_FILE" ]]; then
        backup="$(mktemp)"
        cp -p "$SSH_ALLOW_F2B_FILE" "$backup"
    fi
    install -m 644 "$tmp" "$SSH_ALLOW_F2B_FILE"
    rm -f "$tmp"
    if ! fail2ban-client -t >/dev/null; then
        error "fail2ban の設定検査に失敗しました。${SSH_ALLOW_F2B_FILE} を元に戻します。"
        if [[ -n "$backup" ]]; then
            mv "$backup" "$SSH_ALLOW_F2B_FILE"
        else
            rm -f "$SSH_ALLOW_F2B_FILE"
        fi
        return 1
    fi
    [[ -n "$backup" ]] && rm -f "$backup"
    if systemctl is-active --quiet fail2ban.service; then
        fail2ban-client reload >/dev/null
    fi
    success "fail2ban ignoreip を更新しました: ${addrs}"
}

# UFW の SSH ルールと fail2ban ignoreip を許可リストに合わせる (冪等)
# 許可リストが空 / 無いときは何も変えずに 1 を返す (締め出し防止)
ssh_allow_apply() {
    local -a ports=() entries=()
    mapfile -t ports < <(ssh_allow_listen_ports)
    mapfile -t entries < <(ssh_allow_read_list)
    if ((${#entries[@]} == 0)); then
        warn "許可リスト ${SSH_ALLOW_LIST} が空のため、SSH のルールは変更しません。"
        return 1
    fi

    local -A wanted=()
    local entry addr memo port
    # 先に許可 IP のルールを入れてから古いルールを消す (作業中のセッションを切らない)
    for entry in "${entries[@]}"; do
        memo="${entry#*$'\t'}"
        # 手で編集されたリストでも UFW 側の表記と比較できるよう正規化する
        if ! addr="$(ssh_allow_normalize "${entry%%$'\t'*}")"; then
            warn "不正なアドレスをスキップ: ${entry%%$'\t'*}"
            continue
        fi
        wanted["$addr"]=1
        for port in "${ports[@]}"; do
            ufw allow proto tcp from "$addr" to any port "$port" comment "SSH allow: ${memo:-$addr}" >/dev/null
        done
    done
    if ((${#wanted[@]} == 0)); then
        warn "許可リストに有効なアドレスが無いため、古い SSH ルールは削除しません。"
        return 1
    fi

    # 削除中に user.rules が書き換わるので、先に全部読み込んでおく
    local -a current=()
    mapfile -t current < <(ssh_allow_ufw_rules)
    local rule rule_port proto src app norm
    for rule in "${current[@]}"; do
        IFS=$'\t' read -r rule_port proto src app <<< "$rule"
        [[ -n "$rule_port" ]] || continue
        if [[ "$app" != "-" ]]; then
            ufw delete allow "$(printf '%b' "${app//%/\\x}")" >/dev/null 2>&1 || true
            info "削除: ${app} (全体に公開)"
            continue
        fi
        if [[ "$src" == "any" ]]; then
            if [[ "$proto" == "any" ]]; then
                ufw delete allow "$rule_port" >/dev/null 2>&1 || true
            else
                ufw delete allow "${rule_port}/${proto}" >/dev/null 2>&1 || true
            fi
            info "削除: ${rule_port}/${proto} Anywhere"
            continue
        fi
        norm="$(ssh_allow_normalize "$src" || true)"
        [[ -n "$norm" && -n "${wanted[$norm]:-}" ]] && continue
        if [[ "$proto" == "any" ]]; then
            ufw delete allow from "$src" to any port "$rule_port" >/dev/null 2>&1 || true
        else
            ufw delete allow proto "$proto" from "$src" to any port "$rule_port" >/dev/null 2>&1 || true
        fi
        info "削除: ${rule_port}/${proto} from ${src}"
    done

    success "UFW の SSH ルールを許可リストに合わせました (ポート: $(IFS=,; echo "${ports[*]}"))"
    _ssh_allow_sync_fail2ban
}

# 絞り込みをやめて SSH を全体 (Anywhere) に開く。先に Anywhere を入れてから IP ごとのルールを消す
ssh_allow_open() {
    local -a ports=() current=()
    mapfile -t ports < <(ssh_allow_listen_ports)
    local port
    for port in "${ports[@]}"; do
        ufw allow "${port}/tcp" comment 'SSH' >/dev/null
    done

    mapfile -t current < <(ssh_allow_ufw_rules)
    local rule rule_port proto src app
    for rule in "${current[@]}"; do
        IFS=$'\t' read -r rule_port proto src app <<< "$rule"
        [[ -n "$rule_port" && "$app" == "-" && "$src" != "any" ]] || continue
        if [[ "$proto" == "any" ]]; then
            ufw delete allow from "$src" to any port "$rule_port" >/dev/null 2>&1 || true
        else
            ufw delete allow proto "$proto" from "$src" to any port "$rule_port" >/dev/null 2>&1 || true
        fi
        info "削除: ${rule_port}/${proto} from ${src}"
    done
    success "SSH を全体に公開しました (ポート: $(IFS=,; echo "${ports[*]}"))"
}
