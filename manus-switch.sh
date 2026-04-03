#!/bin/bash
# manus-switch.sh — Manus Desktop multi-account manager
# Isolated profiles via Electron --user-data-dir, credentials in macOS Keychain
#
# Usage:
#   manus-switch.sh              # Interactive picker
#   manus-switch.sh 2            # Launch profile #2 directly
#   manus-switch.sh add <email> <password> [name] [desc]  # Add account
#   manus-switch.sh info [number] # Show account info
#   manus-switch.sh list         # List all profiles with status
#   manus-switch.sh rm <name>    # Unregister profile (keeps data)
#   manus-switch.sh purge <name> # Remove profile AND delete data
#   manus-switch.sh cred <number>  # Show stored credentials

set -euo pipefail

MANUS_APP="/Applications/Manus.app"
PROFILES_DIR="$HOME/.manus-profiles"
PROFILES_CONF="$PROFILES_DIR/.profiles"
KEYCHAIN_SERVICE="manus-switch"

# Colors — use $'...' so escape chars are real bytes, not literal \033
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ━━━ Init ━━━
init() {
    mkdir -p "$PROFILES_DIR"
    if [[ ! -f "$PROFILES_CONF" ]]; then
        local default_email=""
        local ls_file="$HOME/Library/Application Support/Manus/localStorage.json"
        if [[ -f "$ls_file" ]]; then
            default_email=$(python3 -c "
import json, base64
with open('$ls_file') as f: d=json.load(f)
t=d.get('token','')
if t:
    p=t.split('.')[1]
    p+='='*(4-len(p)%4)
    print(json.loads(base64.urlsafe_b64decode(p)).get('email',''))
" 2>/dev/null || echo "")
        fi
        echo "default|$HOME/Library/Application Support/Manus|${default_email}|Main account (original)" > "$PROFILES_CONF"
        printf "%s\n" "${GREEN}Initialized. Original Manus data registered as 'default'.${NC}"
    fi
}

# ━━━ Keychain helpers ━━━
keychain_set() {
    local account="$1" password="$2"
    security add-generic-password -a "$account" -s "$KEYCHAIN_SERVICE" -w "$password" -U 2>/dev/null
}

keychain_get() {
    local account="$1"
    security find-generic-password -a "$account" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || echo ""
}

keychain_delete() {
    local account="$1"
    security delete-generic-password -a "$account" -s "$KEYCHAIN_SERVICE" 2>/dev/null || true
}

# ━━━ Profile helpers ━━━
get_profile_count() {
    wc -l < "$PROFILES_CONF" | tr -d ' '
}

get_profile_by_index() {
    sed -n "${1}p" "$PROFILES_CONF"
}

get_profile_by_name() {
    grep "^${1}|" "$PROFILES_CONF" || echo ""
}

# ━━━ Token / Account Info ━━━
parse_token_info() {
    local data_dir="$1"
    local ls_file="$data_dir/localStorage.json"
    if [[ ! -f "$ls_file" ]]; then
        echo "NO_TOKEN"
        return
    fi
    python3 << PYEOF
import json, base64, datetime, os

try:
    with open("$ls_file") as f:
        data = json.load(f)
    token = data.get("token", "")
    if not token:
        print("NO_TOKEN")
        exit()
    payload = token.split(".")[1]
    payload += "=" * (4 - len(payload) % 4)
    decoded = json.loads(base64.urlsafe_b64decode(payload))
    exp = datetime.datetime.fromtimestamp(decoded["exp"])
    now = datetime.datetime.now()
    days_left = (exp - now).days
    status = "VALID" if days_left > 0 else "EXPIRED"
    print(f"{status}|{decoded.get('email','')}|{decoded.get('name','')}|{decoded.get('user_id','')}|{exp.strftime('%Y-%m-%d')}|{days_left}")
except:
    print("NO_TOKEN")
PYEOF
}

# ━━━ Manus API calls ━━━
MANUS_API="https://api.manus.im"

get_token_from_profile() {
    local data_dir="$1"
    local ls_file="$data_dir/localStorage.json"
    if [[ -f "$ls_file" ]]; then
        python3 -c "import json,os; print(json.load(open('$ls_file')).get('token',''))" 2>/dev/null
    fi
}

api_get_credits() {
    local token="$1"
    [[ -z "$token" ]] && return
    curl -s -X POST "$MANUS_API/user.v1.UserService/GetAvailableCredits" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "x-client-locale: en" \
        -d '{}' 2>/dev/null
}

api_get_user_info() {
    local token="$1"
    [[ -z "$token" ]] && return
    curl -s -X POST "$MANUS_API/user.v1.UserService/UserInfo" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "x-client-locale: en" \
        -d '{}' 2>/dev/null
}

# ━━━ Async credit display helpers ━━━
_CREDIT_TMPDIR=""
_CREDIT_BG_PID=""

_cleanup_credit() {
    if [[ -n "$_CREDIT_BG_PID" ]]; then
        kill "$_CREDIT_BG_PID" 2>/dev/null
        wait "$_CREDIT_BG_PID" 2>/dev/null
        _CREDIT_BG_PID=""
    fi
    if [[ -n "$_CREDIT_TMPDIR" ]]; then
        rm -rf "$_CREDIT_TMPDIR"
        _CREDIT_TMPDIR=""
    fi
}

# Background job: poll for curl results, then overwrite "..." placeholders via ANSI
_start_credit_bg() {
    local tmpdir="$_CREDIT_TMPDIR"
    local menu_lines="$1"
    [[ -f "$tmpdir/_cpos" ]] || return

    local profile_lc
    profile_lc=$(cat "$tmpdir/_lc")

    (
        # Poll until all credit files exist or timeout (8s)
        local deadline=$((SECONDS + 8))
        while (( SECONDS < deadline )); do
            local all_done=true
            while read -r idx pos; do
                [[ -s "$tmpdir/${idx}_credits" ]] || { all_done=false; break; }
            done < "$tmpdir/_cpos"
            $all_done && break
            sleep 0.2
        done

        # Update each credit line in-place
        while read -r idx pos; do
            if [[ -s "$tmpdir/${idx}_credits" ]]; then
                local up=$(( profile_lc + menu_lines - pos ))
                local credit_text
                credit_text=$(python3 -c "
import json
with open('$tmpdir/${idx}_credits') as f: c = json.load(f)
u = {}
try:
    with open('$tmpdir/${idx}_userinfo') as f: u = json.load(f)
except: pass
total = c.get('totalCredits', 0)
refresh = c.get('refreshCredits', 0)
mx = c.get('maxRefreshCredits', 0)
balance = total - refresh
plan = ''
if u:
    plan = u.get('membershipVersion','free').upper() + ' (' + u.get('subscriptionStatus','').replace('SubscriptionStatus','') + ')'
print(f'\033[0;32m{balance} credits | daily: {refresh}/{mx} left\033[0m  \033[2m{plan}\033[0m')
" 2>/dev/null)
                if [[ -n "$credit_text" ]]; then
                    # save cursor → move up → col 1 → print → clear EOL → restore cursor
                    printf "\033[s\033[%dA\r      %14s%s\033[K\033[u" "$up" "" "$credit_text"
                fi
            fi
        done < "$tmpdir/_cpos"
    ) &
    _CREDIT_BG_PID=$!
}

# ━━━ List profiles ━━━
# mode: "sync" (default) = wait for credits inline; "async" = show placeholders
list_profiles() {
    local mode="${1:-sync}"
    _cleanup_credit
    _CREDIT_TMPDIR=$(mktemp -d)
    local tmpdir="$_CREDIT_TMPDIR"

    # Spawn ALL API calls in parallel
    local i=1
    while IFS='|' read -r name path email desc; do
        local token
        token=$(get_token_from_profile "$path")
        if [[ -n "$token" ]]; then
            api_get_credits "$token" > "$tmpdir/${i}_credits" 2>/dev/null &
            api_get_user_info "$token" > "$tmpdir/${i}_userinfo" 2>/dev/null &
        fi
        ((i++))
    done < "$PROFILES_CONF"

    # In sync mode, wait before display so credits are ready
    [[ "$mode" == "sync" ]] && wait

    printf "\n%s\n" "${BOLD}${CYAN}======= Manus Account Manager =======${NC}"
    echo ""

    local lc=0  # line counter for async credit positioning
    i=1
    while IFS='|' read -r name path email desc; do
        local login_status="" token_info=""

        token_info=$(parse_token_info "$path")
        if [[ "$token_info" == "NO_TOKEN" ]]; then
            local created=""
            if [[ -d "$path" ]]; then
                created=$(stat -f "%SB" -t "%Y-%m-%d" "$path" 2>/dev/null)
            fi
            if [[ -n "$created" ]]; then
                login_status="${YELLOW}[fresh]${NC} added ${created}"
            else
                login_status="${YELLOW}[fresh]${NC}"
            fi
        else
            IFS='|' read -r tstatus temail tname tuid texp tdays <<< "$token_info"
            if [[ "$tstatus" == "VALID" ]]; then
                login_status="${GREEN}[logged in]${NC} expires ${texp} (${tdays}d)"
                if [[ -z "$email" && -n "$temail" ]]; then
                    email="$temail"
                fi
            else
                login_status="${RED}[token expired]${NC}"
            fi
        fi

        local has_pwd=""
        if [[ -n "$email" ]]; then
            local pwd
            pwd=$(keychain_get "$email")
            if [[ -n "$pwd" ]]; then
                has_pwd=" ${DIM}[pwd saved]${NC}"
            fi
        fi

        printf "  ${BLUE}%2d${NC}  %-12s  %s\n" "$i" "$name" "$login_status"
        ((lc++))
        if [[ -n "$email" ]]; then
            printf "      %14s%s%s\n" "" "$email" "$has_pwd"
            ((lc++))
        fi
        if [[ -n "$desc" ]]; then
            printf "      %14s${DIM}%s${NC}\n" "" "$desc"
            ((lc++))
        fi

        # Credit line
        local token
        token=$(get_token_from_profile "$path")
        if [[ -n "$token" ]]; then
            if [[ "$mode" == "sync" && -s "$tmpdir/${i}_credits" ]]; then
                # Sync: credits already fetched, display inline
                local credit_line plan
                credit_line=$(python3 -c "
import json
with open('$tmpdir/${i}_credits') as f: c = json.load(f)
total = c.get('totalCredits', 0)
refresh = c.get('refreshCredits', 0)
mx = c.get('maxRefreshCredits', 0)
balance = total - refresh
print(f'{balance} credits | daily: {refresh}/{mx} left')
" 2>/dev/null)
                plan=$(python3 -c "
import json
try:
    with open('$tmpdir/${i}_userinfo') as f: u = json.load(f)
    print(u.get('membershipVersion','free').upper() + ' (' + u.get('subscriptionStatus','').replace('SubscriptionStatus','') + ')')
except: print('')
" 2>/dev/null)
                printf "      %14s${GREEN}%s${NC}  ${DIM}%s${NC}\n" "" "$credit_line" "$plan"
            else
                # Async: placeholder, record position for background update
                echo "$i $lc" >> "$tmpdir/_cpos"
                printf "      %14s${DIM}...${NC}\n" ""
            fi
            ((lc++))
        fi

        echo ""
        ((lc++))
        ((i++))
    done < "$PROFILES_CONF"

    echo "$lc" > "$tmpdir/_lc"

    # Sync mode: done, clean up
    if [[ "$mode" == "sync" ]]; then
        rm -rf "$tmpdir"
        _CREDIT_TMPDIR=""
    fi
}

# ━━━ Account info (detailed) ━━━
show_info() {
    local index="${1:-}"
    if [[ -z "$index" ]]; then
        local i=1
        local count
        count=$(get_profile_count)
        while (( i <= count )); do
            show_single_info "$i"
            echo ""
            ((i++))
        done
        return
    fi
    show_single_info "$index"
}

show_single_info() {
    local index="$1"
    local line
    line=$(get_profile_by_index "$index")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Invalid profile #${index}${NC}"
        return 1
    fi

    local name path email desc
    IFS='|' read -r name path email desc <<< "$line"

    printf "\n%s\n" "${CYAN}--- Profile #${index}: ${name} ---${NC}"
    printf "  %-10s %s\n" "Data dir:" "$path"
    printf "  %-10s %s\n" "Email:" "${email:-<not set>}"

    if [[ -n "$email" ]]; then
        local pwd
        pwd=$(keychain_get "$email")
        if [[ -n "$pwd" ]]; then
            printf "  %-10s %s\n" "Password:" "${GREEN}stored in Keychain${NC}"
        else
            printf "  %-10s %s\n" "Password:" "${YELLOW}not stored${NC}"
        fi
    fi

    local token_info
    token_info=$(parse_token_info "$path")
    if [[ "$token_info" == "NO_TOKEN" ]]; then
        printf "  %-10s %s\n" "Session:" "${YELLOW}not logged in${NC}"
    else
        IFS='|' read -r tstatus temail tname tuid texp tdays <<< "$token_info"
        printf "  %-10s %s\n" "Session:" "$tstatus"
        printf "  %-10s %s (%s)\n" "User:" "$tname" "$temail"
        printf "  %-10s %s\n" "UserID:" "$tuid"
        printf "  %-10s %s (%s days left)\n" "Expires:" "$texp" "$tdays"
    fi

    if [[ -d "$path" ]]; then
        local size
        size=$(du -sh "$path" 2>/dev/null | cut -f1)
        printf "  %-10s %s\n" "Disk:" "$size"
    fi

    # Live API data
    local token
    token=$(get_token_from_profile "$path")
    if [[ -n "$token" ]]; then
        echo ""
        printf "  ${CYAN}--- Live Account Data ---${NC}\n"

        local credits_json user_json
        credits_json=$(api_get_credits "$token")
        user_json=$(api_get_user_info "$token")

        if [[ -n "$credits_json" ]]; then
            python3 << PYEOF2
import json, datetime
try:
    c = json.loads('''$credits_json''')
    u = json.loads('''$user_json''')
    plan = u.get("membershipVersion", "free").upper()
    status = u.get("subscriptionStatus", "").replace("SubscriptionStatus", "")
    interval = u.get("membershipInterval", "")
    renewal_ts = int(u.get("currentPeriodEnd", "0"))
    renewal = datetime.datetime.fromtimestamp(renewal_ts).strftime("%Y-%m-%d") if renewal_ts else "N/A"
    total = c.get("totalCredits", 0)
    free = c.get("freeCredits", 0)
    monthly_max = c.get("proMonthlyCredits", 0)
    monthly_used = monthly_max - (total - free) if monthly_max else 0
    refresh = c.get("refreshCredits", 0)
    max_refresh = c.get("maxRefreshCredits", 0)
    next_refresh = c.get("nextRefreshTime", "")
    if next_refresh:
        dt = datetime.datetime.fromisoformat(next_refresh.replace("Z", "+00:00"))
        next_refresh = dt.strftime("%Y-%m-%d %H:%M UTC")

    balance = total - refresh  # what the app shows
    periodic = c.get("periodicCredits", 0)
    print(f"  {'Plan:':10s} {plan} ({status}, {interval})")
    print(f"  {'Renewal:':10s} {renewal}")
    print(f"  {'Credits:':10s} {balance:,} (matches app display)")
    print(f"  {'Breakdown:':10s} free:{free:,} + periodic:{periodic:,} + daily:{refresh}/{max_refresh}")
    print(f"  {'Daily:':10s} resets {next_refresh}")
except Exception as e:
    print(f"  API error: {e}")
PYEOF2
        else
            printf "  %s\n" "${YELLOW}Could not reach Manus API${NC}"
        fi
    fi
}

# ━━━ Show credentials ━━━
show_cred() {
    local index="$1"
    local line
    line=$(get_profile_by_index "$index")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Invalid profile #${index}${NC}"
        return 1
    fi

    local name path email desc
    IFS='|' read -r name path email desc <<< "$line"

    if [[ -z "$email" ]]; then
        printf "%s\n" "${RED}No email set for profile '$name'.${NC}"
        return 1
    fi

    local pwd
    pwd=$(keychain_get "$email")
    printf "  Profile:  %s\n" "$name"
    printf "  Email:    %s\n" "$email"
    if [[ -n "$pwd" ]]; then
        printf "  Password: %s\n" "$pwd"
    else
        printf "  Password: %s\n" "${YELLOW}(not stored)${NC}"
    fi
}

# ━━━ Add profile ━━━
add_profile() {
    local email="${1:?Usage: manus add <email> <password> [name] [description]}"
    local password="${2:?Password required}"
    local name="${3:-$(echo "$email" | cut -d@ -f1)}"
    local desc="${4:-}"

    if grep -q "^${name}|" "$PROFILES_CONF" 2>/dev/null; then
        printf "%s\n" "${RED}Profile name '$name' already exists.${NC}"
        return 1
    fi

    local path="$PROFILES_DIR/$name"
    mkdir -p "$path"

    keychain_set "$email" "$password"

    echo "${name}|${path}|${email}|${desc}" >> "$PROFILES_CONF"
    printf "%s\n" "${GREEN}Added profile '$name'${NC}"
    printf "  Email:    %s\n" "$email"
    printf "  Password: %s\n" "${GREEN}stored in macOS Keychain${NC}"
    printf "  Data dir: %s\n" "$path"
    echo ""
    printf "%s\n" "${YELLOW}Launch to log in: manus (pick from menu)${NC}"
}

# ━━━ Remove profile ━━━
rm_profile() {
    local name="${1:?Usage: manus rm <name>}"
    if [[ "$name" == "default" ]]; then
        printf "%s\n" "${RED}Cannot remove the default profile.${NC}"
        return 1
    fi
    local line
    line=$(get_profile_by_name "$name")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Profile '$name' not found.${NC}"
        return 1
    fi
    sed -i '' "/^${name}|/d" "$PROFILES_CONF"
    printf "%s\n" "${GREEN}Removed profile '$name' (data & keychain preserved).${NC}"
}

purge_profile() {
    local name="${1:?Usage: manus purge <name>}"
    if [[ "$name" == "default" ]]; then
        printf "%s\n" "${RED}Cannot purge the default profile.${NC}"
        return 1
    fi
    local line
    line=$(get_profile_by_name "$name")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Profile '$name' not found.${NC}"
        return 1
    fi
    local path email
    path=$(echo "$line" | cut -d'|' -f2)
    email=$(echo "$line" | cut -d'|' -f3)

    read -rp "Delete profile '$name', all data, and keychain entry? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$path"
        sed -i '' "/^${name}|/d" "$PROFILES_CONF"
        if [[ -n "$email" ]]; then
            keychain_delete "$email"
        fi
        printf "%s\n" "${GREEN}Purged profile '$name' completely.${NC}"
    else
        echo "Aborted."
    fi
}

# ━━━ Launch profile (new window, keeps existing) ━━━
launch_profile() {
    local index="$1"
    local line
    line=$(get_profile_by_index "$index")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Invalid profile number.${NC}"
        return 1
    fi

    local name path email desc
    IFS='|' read -r name path email desc <<< "$line"

    printf "%s\n" "${GREEN}Launching Manus as '$name'...${NC}"
    [[ -n "$email" ]] && printf "  %s\n" "$email"

    if [[ "$name" == "default" ]]; then
        open -n -a "$MANUS_APP" &
    else
        open -n -a "$MANUS_APP" --args --user-data-dir="$path" &
    fi

    printf "%s\n" "${CYAN}Manus window opened.${NC}"

    # Show credentials if fresh profile
    local token_info
    token_info=$(parse_token_info "$path")
    if [[ "$token_info" == "NO_TOKEN" && -n "$email" ]]; then
        local pwd
        pwd=$(keychain_get "$email")
        if [[ -n "$pwd" ]]; then
            echo ""
            printf "%s\n" "${YELLOW}First login needed:${NC}"
            printf "  Email:    %s\n" "$email"
            printf "  Password: %s\n" "$pwd"
        fi
    fi
}

# ━━━ Sync deviceId so "My Computer" works across profiles ━━━
sync_device_id() {
    local target_path="$1"
    local default_ls="$HOME/Library/Application Support/Manus/localStorage.json"
    local target_ls="$target_path/localStorage.json"

    if [[ ! -f "$default_ls" || ! -f "$target_ls" ]]; then
        return
    fi

    local default_did
    default_did=$(python3 -c "import json; print(json.load(open('$default_ls')).get('deviceId',''))" 2>/dev/null)
    if [[ -z "$default_did" ]]; then
        return
    fi

    # Overwrite target's deviceId with default's so Manus sees the same device
    python3 -c "
import json
with open('$target_ls') as f: d = json.load(f)
d['deviceId'] = '$default_did'
with open('$target_ls', 'w') as f: json.dump(d, f)
" 2>/dev/null
}

# ━━━ Switch profile (close all, open one) ━━━
switch_profile() {
    local index="$1"
    local line
    line=$(get_profile_by_index "$index")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Invalid profile number.${NC}"
        return 1
    fi

    local name path email desc
    IFS='|' read -r name path email desc <<< "$line"

    # Sync deviceId for My Computer
    if [[ "$name" != "default" ]]; then
        sync_device_id "$path"
    fi

    printf "%s\n" "${YELLOW}Closing all Manus instances...${NC}"
    osascript -e 'quit app "Manus"' 2>/dev/null || true
    sleep 2
    # Force kill any remaining
    pkill -f "Manus.app" 2>/dev/null || true
    sleep 1

    printf "%s\n" "${GREEN}Launching Manus as '$name'...${NC}"
    if [[ "$name" == "default" ]]; then
        open -a "$MANUS_APP" &
    else
        open -a "$MANUS_APP" --args --user-data-dir="$path" &
    fi

    printf "%s\n" "${CYAN}Switched to: $name ($email)${NC}"

    local token_info
    token_info=$(parse_token_info "$path")
    if [[ "$token_info" == "NO_TOKEN" && -n "$email" ]]; then
        local pwd
        pwd=$(keychain_get "$email")
        if [[ -n "$pwd" ]]; then
            printf "%s\n" "${YELLOW}Login with: $email / $pwd${NC}"
        fi
    fi

    # Auto-sync knowledge from the largest knowledge pool
    auto_sync_knowledge "$index"
}

# ━━━ Interactive menu ━━━
interactive_pick() {
    list_profiles async
    local count
    count=$(get_profile_count)

    # Menu: 9 lines (must match menu_lines passed to _start_credit_bg)
    printf "  Commands:\n"
    printf "    ${BLUE}1-%s${NC}     Launch profile (new window, keeps current)\n" "$count"
    printf "    ${BLUE}s1-%s${NC}    Switch (close all, open one)\n" "$count"
    printf "    ${BLUE}i${NC}[num]  Account info\n"
    printf "    ${BLUE}c${NC}[num]  Show credentials\n"
    printf "    ${BLUE}k${NC}       Knowledge entries\n"
    printf "    ${BLUE}a${NC}       Add new account\n"
    printf "    ${BLUE}q${NC}       Quit\n"
    echo ""

    # Start background job that fills in "..." credit placeholders via ANSI
    _start_credit_bg 9

    read -rp "  > " choice

    # User made a choice — kill background updater, clean up
    _cleanup_credit

    case "$choice" in
        q|Q) exit 0 ;;
        a|A)
            read -rp "  Email: " pemail
            read -rsp "  Password: " ppwd
            echo ""
            read -rp "  Profile name [${pemail%%@*}]: " pname
            pname="${pname:-${pemail%%@*}}"
            read -rp "  Description (optional): " pdesc
            add_profile "$pemail" "$ppwd" "$pname" "$pdesc"
            echo ""
            interactive_pick
            ;;
        k|K)
            show_knowledge
            interactive_pick
            ;;
        i|I)
            show_info
            interactive_pick
            ;;
        i[0-9]*|I[0-9]*)
            show_info "${choice:1}"
            interactive_pick
            ;;
        c[0-9]*|C[0-9]*)
            show_cred "${choice:1}"
            echo ""
            interactive_pick
            ;;
        s[0-9]*|S[0-9]*)
            local num="${choice:1}"
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= count )); then
                switch_profile "$num"
            else
                printf "%s\n" "${RED}Invalid profile number.${NC}"
                interactive_pick
            fi
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
                launch_profile "$choice"
            else
                printf "%s\n" "${RED}Invalid choice.${NC}"
                interactive_pick
            fi
            ;;
    esac
}

# ━━━ Quick credit check (all profiles, one line each) ━━━
show_credits() {
    local i=1
    while IFS='|' read -r name path email desc; do
        local token
        token=$(get_token_from_profile "$path")
        if [[ -n "$token" ]]; then
            local cred_json
            cred_json=$(api_get_credits "$token" 2>/dev/null)
            if [[ -n "$cred_json" ]]; then
                python3 << PYEOF3
import json, datetime
c = json.loads('''$cred_json''')
total = c.get("totalCredits", 0)
refresh = c.get("refreshCredits", 0)
mx = c.get("maxRefreshCredits", 0)
balance = total - refresh  # what the app top bar shows
nxt = c.get("nextRefreshTime", "")
hrs = ""
if nxt:
    dt = datetime.datetime.fromisoformat(nxt.replace("Z", "+00:00"))
    now = datetime.datetime.now(datetime.timezone.utc)
    delta = dt - now
    h, m = delta.seconds // 3600, (delta.seconds % 3600) // 60
    hrs = f"{h}h{m}m"
print(f"  {$i}  {'{:<12}'.format('$name')}  {balance:>5} credits  (+{mx} daily in {hrs})")
PYEOF3
            fi
        else
            printf "  %d  %-12s  %s\n" "$i" "$name" "${YELLOW}not logged in${NC}"
        fi
        ((i++))
    done < "$PROFILES_CONF"
}

# ━━━ Watch credits (auto-refresh) ━━━
watch_credits() {
    local interval="${1:-30}"
    trap 'printf "\n"; exit 0' INT
    while true; do
        # Move cursor home + clear (no flicker)
        printf "\033[H\033[J"
        printf "%s  %s  ${DIM}(every %ss, Ctrl+C stop)${NC}\n\n" "${BOLD}${CYAN}Manus Credits${NC}" "$(date '+%H:%M:%S')" "$interval"
        show_credits
        sleep "$interval"
    done
}

# ━━━ Daily checkin: ping all accounts to ensure activity + log credits ━━━
CHECKIN_LOG="$PROFILES_DIR/.checkin.log"

daily_checkin() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local i=1
    local total_credits=0

    printf "%s\n" "${CYAN}=== Daily Check-in: $timestamp ===${NC}"

    while IFS='|' read -r name path email desc; do
        local token
        token=$(get_token_from_profile "$path")
        if [[ -z "$token" ]]; then
            printf "  %d  %-12s  ${YELLOW}SKIP (not logged in)${NC}\n" "$i" "$name"
            echo "$timestamp | $name | SKIP | not logged in" >> "$CHECKIN_LOG"
            ((i++))
            continue
        fi

        # Ping 1: UserInfo (authenticates the session)
        local uinfo
        uinfo=$(api_get_user_info "$token" 2>/dev/null)

        # Ping 2: GetAvailableCredits (triggers credit check)
        local cred_json
        cred_json=$(api_get_credits "$token" 2>/dev/null)

        if [[ -n "$cred_json" ]]; then
            local free
            free=$(echo "$cred_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('freeCredits',0))" 2>/dev/null)
            printf "  %d  %-12s  ${GREEN}OK${NC}  %s credits  (%s)\n" "$i" "$name" "$free" "$email"
            echo "$timestamp | $name | OK | $free credits | $email" >> "$CHECKIN_LOG"
            total_credits=$((total_credits + free))
        else
            # Token might be expired — try to detect
            local token_info
            token_info=$(parse_token_info "$path")
            if [[ "$token_info" == *"EXPIRED"* ]]; then
                printf "  %d  %-12s  ${RED}EXPIRED${NC} — needs manual re-login\n" "$i" "$name"
                echo "$timestamp | $name | EXPIRED | needs re-login | $email" >> "$CHECKIN_LOG"
            else
                printf "  %d  %-12s  ${RED}FAIL${NC} — API unreachable\n" "$i" "$name"
                echo "$timestamp | $name | FAIL | API error | $email" >> "$CHECKIN_LOG"
            fi
        fi
        ((i++))
    done < "$PROFILES_CONF"

    printf "\n  ${BOLD}Total across all accounts: %s credits${NC}\n" "$total_credits"
    echo "$timestamp | TOTAL | $total_credits credits" >> "$CHECKIN_LOG"
}

# ━━━ Show checkin history ━━━
checkin_log() {
    local lines="${1:-20}"
    if [[ ! -f "$CHECKIN_LOG" ]]; then
        printf "%s\n" "${YELLOW}No check-in history yet. Run: manus checkin${NC}"
        return
    fi
    printf "%s\n\n" "${CYAN}=== Check-in History (last $lines) ===${NC}"
    tail -n "$lines" "$CHECKIN_LOG"
}

# ━━━ Knowledge API ━━━
KNOWLEDGE_DIR="$PROFILES_DIR/.knowledge"

api_list_knowledge() {
    local token="$1"
    [[ -z "$token" ]] && return
    curl -s -X POST "$MANUS_API/knowledge.v1.KnowledgeService/ListKnowledge" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"limit": 100}' 2>/dev/null
}

api_create_knowledge() {
    local token="$1" name="$2" content="$3" trigger="$4"
    [[ -z "$token" ]] && return
    local payload
    payload=$(python3 -c "
import json
print(json.dumps({
    'name': '''$name''',
    'content': '''$content''',
    'trigger': '''$trigger'''
}))
" 2>/dev/null)
    curl -s -X POST "$MANUS_API/knowledge.v1.KnowledgeService/CreateKnowledge" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null
}

api_delete_knowledge() {
    local token="$1" uid="$2"
    [[ -z "$token" ]] && return
    curl -s -X POST "$MANUS_API/knowledge.v1.KnowledgeService/DeleteKnowledge" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"uid\":\"$uid\"}" 2>/dev/null
}

# ━━━ Knowledge: list for a profile ━━━
show_knowledge() {
    local index="${1:-}"
    if [[ -z "$index" ]]; then
        # Show all profiles
        local i=1
        local count
        count=$(get_profile_count)
        while (( i <= count )); do
            show_profile_knowledge "$i"
            echo ""
            ((i++))
        done
        return
    fi
    show_profile_knowledge "$index"
}

show_profile_knowledge() {
    local index="$1"
    local line
    line=$(get_profile_by_index "$index")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Invalid profile #${index}${NC}"
        return 1
    fi

    local name path email desc
    IFS='|' read -r name path email desc <<< "$line"

    local token
    token=$(get_token_from_profile "$path")
    if [[ -z "$token" ]]; then
        printf "  %s: ${YELLOW}not logged in${NC}\n" "$name"
        return
    fi

    local kdata
    kdata=$(api_list_knowledge "$token")

    python3 << PYEOF
import json
data = json.loads('''$kdata''')
entries = data.get("knowledge", [])
total = data.get("total", len(entries))
print(f"\033[0;36m--- $name: {total} knowledge entries ---\033[0m")
if not entries:
    print("  \033[2m(empty)\033[0m")
else:
    for k in entries:
        kname = k.get("name", "")
        content = k.get("content", "")
        trigger = k.get("trigger", "")
        enabled = k.get("enabled", True)
        status = "\033[0;32m[on]\033[0m" if enabled else "\033[0;31m[off]\033[0m"
        print(f"  {status} {kname}")
        if trigger:
            print(f"       \033[2mWhen: {trigger}\033[0m")
        if content:
            preview = content[:120] + "..." if len(content) > 120 else content
            print(f"       {preview}")
PYEOF
}

# ━━━ Knowledge: export from a profile to JSON file ━━━
export_knowledge() {
    local index="${1:?Usage: manus kexport <profile#> [output.json]}"
    local outfile="${2:-}"
    local line
    line=$(get_profile_by_index "$index")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Invalid profile #${index}${NC}"
        return 1
    fi

    local name path email desc
    IFS='|' read -r name path email desc <<< "$line"

    local token
    token=$(get_token_from_profile "$path")
    if [[ -z "$token" ]]; then
        printf "%s\n" "${RED}Profile '$name' not logged in.${NC}"
        return 1
    fi

    local kdata
    kdata=$(api_list_knowledge "$token")

    mkdir -p "$KNOWLEDGE_DIR"
    if [[ -z "$outfile" ]]; then
        outfile="$KNOWLEDGE_DIR/${name}_$(date '+%Y%m%d_%H%M%S').json"
    fi

    echo "$kdata" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
entries = data.get('knowledge', [])
# Strip server-only fields, keep portable ones
export = []
for k in entries:
    export.append({
        'name': k.get('name', ''),
        'content': k.get('content', ''),
        'trigger': k.get('trigger', ''),
    })
with open('$outfile', 'w') as f:
    json.dump({'source': '$name', 'exported_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)', 'knowledge': export}, f, indent=2)
print(f'Exported {len(export)} entries')
" 2>/dev/null

    printf "%s\n" "${GREEN}Exported to: $outfile${NC}"
}

# ━━━ Knowledge: import into a profile from JSON file ━━━
import_knowledge() {
    local index="${1:?Usage: manus kimport <profile#> <input.json>}"
    local infile="${2:?JSON file required}"
    local line
    line=$(get_profile_by_index "$index")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Invalid profile #${index}${NC}"
        return 1
    fi

    local name path email desc
    IFS='|' read -r name path email desc <<< "$line"

    local token
    token=$(get_token_from_profile "$path")
    if [[ -z "$token" ]]; then
        printf "%s\n" "${RED}Profile '$name' not logged in.${NC}"
        return 1
    fi

    if [[ ! -f "$infile" ]]; then
        printf "%s\n" "${RED}File not found: $infile${NC}"
        return 1
    fi

    # Get existing knowledge to avoid duplicates
    local existing
    existing=$(api_list_knowledge "$token")

    python3 << PYEOF
import json, subprocess, sys

with open("$infile") as f:
    data = json.load(f)

entries = data.get("knowledge", [])
existing = json.loads('''$existing''')
existing_names = {k.get("name", "") for k in existing.get("knowledge", [])}

imported = 0
skipped = 0
for entry in entries:
    name = entry.get("name", "")
    if name in existing_names:
        print(f"  SKIP (exists): {name}")
        skipped += 1
        continue

    payload = json.dumps({
        "name": name,
        "content": entry.get("content", ""),
        "trigger": entry.get("trigger", ""),
    })
    result = subprocess.run([
        "curl", "-s", "-X", "POST",
        "$MANUS_API/knowledge.v1.KnowledgeService/CreateKnowledge",
        "-H", "Authorization: Bearer $token",
        "-H", "Content-Type: application/json",
        "-d", payload
    ], capture_output=True, text=True)
    print(f"  \033[0;32mIMPORTED\033[0m: {name}")
    imported += 1

print(f"\nDone: {imported} imported, {skipped} skipped (duplicates)")
PYEOF
}

# ━━━ Knowledge: deduplicate entries in a profile ━━━
dedup_knowledge() {
    local index="${1:-}"
    if [[ -z "$index" ]]; then
        # Dedup all profiles
        local i=1
        local count
        count=$(get_profile_count)
        while (( i <= count )); do
            dedup_single_knowledge "$i"
            ((i++))
        done
        return
    fi
    dedup_single_knowledge "$index"
}

dedup_single_knowledge() {
    local index="$1"
    local line
    line=$(get_profile_by_index "$index")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Invalid profile #${index}${NC}"
        return 1
    fi

    local name path email desc
    IFS='|' read -r name path email desc <<< "$line"

    local token
    token=$(get_token_from_profile "$path")
    if [[ -z "$token" ]]; then
        printf "  %-12s ${YELLOW}SKIP (not logged in)${NC}\n" "$name"
        return
    fi

    local kdata
    kdata=$(api_list_knowledge "$token")

    python3 << PYEOF
import json, subprocess

data = json.loads('''$kdata''')
entries = data.get("knowledge", [])

seen_names = {}
duplicates = []
for entry in entries:
    ename = entry.get("name", "")
    uid = entry.get("uid", "")
    if ename in seen_names:
        duplicates.append((uid, ename))
    else:
        seen_names[ename] = uid

if not duplicates:
    print(f"  $name: no duplicates found ({len(entries)} entries)")
else:
    for uid, ename in duplicates:
        subprocess.run([
            "curl", "-s", "-X", "POST",
            "$MANUS_API/knowledge.v1.KnowledgeService/DeleteKnowledge",
            "-H", "Authorization: Bearer $token",
            "-H", "Content-Type: application/json",
            "-d", json.dumps({"uid": uid})
        ], capture_output=True, text=True)
        print(f"  $name: \033[0;31mremoved\033[0m duplicate: {ename}")
    print(f"  $name: {len(duplicates)} duplicates removed, {len(entries) - len(duplicates)} remain")
PYEOF
}

# ━━━ Knowledge: remove entry by name from a profile ━━━
rm_knowledge() {
    local index="${1:?Usage: manus krm <profile#> <name>}"
    local target_name="${2:?Knowledge name required}"
    local line
    line=$(get_profile_by_index "$index")
    if [[ -z "$line" ]]; then
        printf "%s\n" "${RED}Invalid profile #${index}${NC}"
        return 1
    fi

    local name path email desc
    IFS='|' read -r name path email desc <<< "$line"

    local token
    token=$(get_token_from_profile "$path")
    if [[ -z "$token" ]]; then
        printf "%s\n" "${RED}Profile '$name' not logged in.${NC}"
        return 1
    fi

    local kdata
    kdata=$(api_list_knowledge "$token")

    python3 << PYEOF
import json, subprocess

data = json.loads('''$kdata''')
target = "$target_name"
deleted = 0
for entry in data.get("knowledge", []):
    if entry.get("name", "") == target:
        uid = entry.get("uid", "")
        subprocess.run([
            "curl", "-s", "-X", "POST",
            "$MANUS_API/knowledge.v1.KnowledgeService/DeleteKnowledge",
            "-H", "Authorization: Bearer $token",
            "-H", "Content-Type: application/json",
            "-d", json.dumps({"uid": uid})
        ], capture_output=True, text=True)
        print(f"  \033[0;32mDeleted\033[0m: {target}")
        deleted += 1
if not deleted:
    print(f"  \033[0;33mNot found\033[0m: {target}")
PYEOF
}

# ━━━ Knowledge: auto-sync to target profile from richest source ━━━
auto_sync_knowledge() {
    local target_index="$1"
    local target_line
    target_line=$(get_profile_by_index "$target_index")
    local target_path
    IFS='|' read -r _ target_path _ _ <<< "$target_line"

    local target_token
    target_token=$(get_token_from_profile "$target_path")
    if [[ -z "$target_token" ]]; then
        return  # target not logged in yet, skip silently
    fi

    # Find the profile with the most knowledge entries
    local best_index=0 best_count=0
    local i=1
    local count
    count=$(get_profile_count)
    while (( i <= count )); do
        if (( i == target_index )); then
            ((i++))
            continue
        fi
        local line
        line=$(get_profile_by_index "$i")
        local spath
        IFS='|' read -r _ spath _ _ <<< "$line"
        local stoken
        stoken=$(get_token_from_profile "$spath")
        if [[ -n "$stoken" ]]; then
            local sdata
            sdata=$(api_list_knowledge "$stoken")
            local stotal
            stotal=$(echo "$sdata" | python3 -c "import json,sys; print(int(json.loads(sys.stdin.read()).get('total','0')))" 2>/dev/null)
            if (( stotal > best_count )); then
                best_count=$stotal
                best_index=$i
            fi
        fi
        ((i++))
    done

    if (( best_index == 0 || best_count == 0 )); then
        return  # no source with knowledge
    fi

    # Sync from best source to target
    local source_line
    source_line=$(get_profile_by_index "$best_index")
    local source_name source_path
    IFS='|' read -r source_name source_path _ _ <<< "$source_line"
    local source_token
    source_token=$(get_token_from_profile "$source_path")
    local source_data
    source_data=$(api_list_knowledge "$source_token")
    local target_data
    target_data=$(api_list_knowledge "$target_token")

    local imported
    imported=$(python3 << PYEOF
import json, subprocess

source = json.loads('''$source_data''')
target = json.loads('''$target_data''')
target_names = {k.get("name", "") for k in target.get("knowledge", [])}

count = 0
for entry in source.get("knowledge", []):
    name = entry.get("name", "")
    if name in target_names:
        continue
    payload = json.dumps({
        "name": name,
        "content": entry.get("content", ""),
        "trigger": entry.get("trigger", ""),
    })
    subprocess.run([
        "curl", "-s", "-X", "POST",
        "$MANUS_API/knowledge.v1.KnowledgeService/CreateKnowledge",
        "-H", "Authorization: Bearer $target_token",
        "-H", "Content-Type: application/json",
        "-d", payload
    ], capture_output=True, text=True)
    count += 1
print(count)
PYEOF
    )

    if [[ "$imported" -gt 0 ]]; then
        printf "%s\n" "${GREEN}Auto-synced ${imported} knowledge entries from '$source_name'${NC}"
    fi
}

# ━━━ Knowledge: sync from one profile to all others ━━━
sync_knowledge() {
    local source_index="${1:?Usage: manus ksync <source_profile#>}"
    local source_line
    source_line=$(get_profile_by_index "$source_index")
    if [[ -z "$source_line" ]]; then
        printf "%s\n" "${RED}Invalid source profile #${source_index}${NC}"
        return 1
    fi

    local source_name source_path
    IFS='|' read -r source_name source_path _ _ <<< "$source_line"

    local source_token
    source_token=$(get_token_from_profile "$source_path")
    if [[ -z "$source_token" ]]; then
        printf "%s\n" "${RED}Source profile '$source_name' not logged in.${NC}"
        return 1
    fi

    printf "%s\n" "${CYAN}=== Syncing knowledge from '$source_name' to all other profiles ===${NC}"

    # Export source knowledge
    local source_data
    source_data=$(api_list_knowledge "$source_token")
    local source_entries
    source_entries=$(echo "$source_data" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d.get('knowledge',[])))" 2>/dev/null)
    printf "  Source: %s entries\n\n" "$source_entries"

    if [[ "$source_entries" == "0" ]]; then
        printf "%s\n" "${YELLOW}No knowledge to sync.${NC}"
        return
    fi

    local i=1
    local count
    count=$(get_profile_count)
    while (( i <= count )); do
        if (( i == source_index )); then
            ((i++))
            continue
        fi

        local line
        line=$(get_profile_by_index "$i")
        local tname tpath
        IFS='|' read -r tname tpath _ _ <<< "$line"

        local ttoken
        ttoken=$(get_token_from_profile "$tpath")
        if [[ -z "$ttoken" ]]; then
            printf "  %-12s ${YELLOW}SKIP (not logged in)${NC}\n" "$tname"
            ((i++))
            continue
        fi

        local existing
        existing=$(api_list_knowledge "$ttoken")

        python3 << PYEOF2
import json, subprocess

source = json.loads('''$source_data''')
target = json.loads('''$existing''')
target_names = {k.get("name", "") for k in target.get("knowledge", [])}

imported = 0
for entry in source.get("knowledge", []):
    name = entry.get("name", "")
    if name in target_names:
        continue
    payload = json.dumps({
        "name": name,
        "content": entry.get("content", ""),
        "trigger": entry.get("trigger", ""),
    })
    subprocess.run([
        "curl", "-s", "-X", "POST",
        "$MANUS_API/knowledge.v1.KnowledgeService/CreateKnowledge",
        "-H", "Authorization: Bearer $ttoken",
        "-H", "Content-Type: application/json",
        "-d", payload
    ], capture_output=True, text=True)
    imported += 1

existing_count = len(target.get("knowledge", []))
print(f"  {'$tname':12s}  \033[0;32m+{imported} new\033[0m  ({existing_count} existed)")
PYEOF2
        ((i++))
    done
    printf "\n%s\n" "${GREEN}Sync complete.${NC}"
}

# ━━━ Setup daily cron ━━━
setup_cron() {
    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    local cron_time="${1:-12 13}"  # default: 13:12 (just after daily refresh at 13:00)
    local minute hour
    read -r minute hour <<< "$cron_time"

    # Check if cron already exists
    if crontab -l 2>/dev/null | grep -q "manus-switch.sh checkin"; then
        printf "%s\n" "${YELLOW}Cron already set up:${NC}"
        crontab -l 2>/dev/null | grep "manus-switch"
        read -rp "Replace? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return
        fi
        # Remove old entry
        crontab -l 2>/dev/null | grep -v "manus-switch.sh checkin" | crontab -
    fi

    # Add new cron entry
    (crontab -l 2>/dev/null; echo "$minute $hour * * * \"$script_path\" checkin >> \"$CHECKIN_LOG\" 2>&1") | crontab -

    printf "%s\n" "${GREEN}Daily check-in scheduled at ${hour}:$(printf '%02d' $minute) every day.${NC}"
    printf "%s\n" "${DIM}This pings all accounts after the 13:00 daily refresh.${NC}"
    printf "%s\n" "${DIM}Log: $CHECKIN_LOG${NC}"
    printf "\n%s\n" "Current crontab:"
    crontab -l 2>/dev/null | grep "manus-switch"
}

# ━━━ Main ━━━
init

case "${1:-}" in
    add)      add_profile "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
    rm)       rm_profile "${2:-}" ;;
    purge)    purge_profile "${2:-}" ;;
    list|ls)  list_profiles ;;
    info)     show_info "${2:-}" ;;
    cred)     show_cred "${2:-}" ;;
    switch)   switch_profile "${2:-}" ;;
    credits|cr) show_credits ;;
    watch)    watch_credits "${2:-30}" ;;
    checkin)  daily_checkin ;;
    log)      checkin_log "${2:-20}" ;;
    cron)     setup_cron "${2:-}" ;;
    knowledge|kn) show_knowledge "${2:-}" ;;
    kexport)  export_knowledge "${2:-}" "${3:-}" ;;
    kimport)  import_knowledge "${2:-}" "${3:-}" ;;
    ksync)    sync_knowledge "${2:-}" ;;
    kdedup)   dedup_knowledge "${2:-}" ;;
    krm)      rm_knowledge "${2:-}" "${3:-}" ;;
    "")       interactive_pick ;;
    *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            launch_profile "$1"
        elif [[ "$1" =~ ^s[0-9]+$ ]]; then
            switch_profile "${1:1}"
        else
            printf "%s\n" "${BOLD}Usage:${NC} manus [command]"
            echo ""
            printf "  %-14s %s\n" "(no args)" "Interactive menu"
            printf "  %-14s %s\n" "<number>" "Launch profile #N (new window)"
            printf "  %-14s %s\n" "s<number>" "Switch to profile #N (close+reopen)"
            printf "  %-14s %s\n" "add" "Add account: add <email> <pwd> [name] [desc]"
            printf "  %-14s %s\n" "list" "List all profiles"
            printf "  %-14s %s\n" "info [N]" "Show account details"
            printf "  %-14s %s\n" "cred N" "Show stored credentials"
            printf "  %-14s %s\n" "rm <name>" "Unregister profile"
            printf "  %-14s %s\n" "purge <name>" "Remove profile + data + keychain"
            echo ""
            printf "  ${BOLD}Knowledge sync:${NC}\n"
            printf "  %-14s %s\n" "kn [N]" "Show knowledge entries"
            printf "  %-14s %s\n" "kexport N" "Export knowledge to JSON"
            printf "  %-14s %s\n" "kimport N file" "Import knowledge from JSON"
            printf "  %-14s %s\n" "ksync N" "Sync knowledge from #N to all others"
            printf "  %-14s %s\n" "kdedup [N]" "Remove duplicate knowledge entries"
            exit 1
        fi
        ;;
esac
