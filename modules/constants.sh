#!/usr/bin/bash

STORAGE="$HOME/storage/shared/Enhancify"
VERSION="$HOME/Enhancify/.info"

if [ -f "$VERSION" ]; then
    source "$VERSION"
fi

ARCH=$(getprop ro.product.cpu.abi)
DPI=$(getprop ro.sf.lcd_density)

USER_AGENT="APKUpdater-3.0.3"
USER_AGENT_GITHUB="Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36 EdgA/142.0.0.0"

PRIVILEGE_STATUS="Non-privilege Mode"
if [ "$ROOT_ACCESS" != false ] && su -c 'exit' &> /dev/null; then
PRIVILEGE_STATUS="Root Mode"
elif [ "$RISH_ACCESS" != false ] && rish -c 'exit' &> /dev/null; then
PRIVILEGE_STATUS="Rish Mode"
fi

APKMIRROR_REACHABLE=false
GITHUB_REACHABLE=false

if ping -c 1 apkmirror.com &> /dev/null; then
    APKMIRROR_REACHABLE=true
fi

if ping -c 1 github.com &> /dev/null; then
    GITHUB_REACHABLE=true
fi

if $APKMIRROR_REACHABLE && $GITHUB_REACHABLE; then
    ONLINE_STATUS="Online"
elif $APKMIRROR_REACHABLE; then
    ONLINE_STATUS="Partial (Github Down)"
elif $GITHUB_REACHABLE; then
    ONLINE_STATUS="Partial (Apkmirror Down)"
else
    ONLINE_STATUS="Offline"
fi

DIALOG=(dialog --backtitle "Enhancify $VERSION | $PRIVILEGE_STATUS | $ONLINE_STATUS" --no-shadow --begin 2 0)

CURL=(curl -sL --fail-early --connect-timeout 2 --max-time 5 -H 'Cache-Control: no-cache')

WGET=(wget -qc --show-progress --user-agent="$USER_AGENT")

NAVIGATION_HINT="Navigate with [↑] [↓] [←] [→]"
SELECTION_HINT="Select with [SPACE]"

source .config

[ "$GREEN_THEME" == "on" ] && THEME="GREEN" || THEME="DARK"
export DIALOGRC="config/.DIALOGRC_$THEME"

ENHANCIFY_ART="   ____     __                 _ ___    \n  / __/__  / /  ___ ____  ____(_) _/_ __\n / _// _ \/ _ \/ _ \`/ _ \\/ __/ / _/ // /\n/___/_//_/_//_/\\_,_/_//_/\\__/_/_/ \\_, / \n                                 /___/  "

dialog --keep-window --no-shadow --keep-window --infobox "\n$ENHANCIFY_ART\n\nModifier     : Graywizard\nLast Updated : Checking...\nStatus       : Checking..." 13 45
sleep 3

if $GITHUB_REACHABLE; then
    git pull >/dev/null 2>&1 || (git fetch --all >/dev/null 2>&1 && git reset --hard "@{u}" >/dev/null 2>&1)
    LAST_UPDATED=$(git log -1 --pretty='format:%cd' --date=format:'%b %d, %Y | %H:%M')
else
    LAST_UPDATED=$(git log -1 --pretty='format:%cd' --date=format:'%b %d, %Y | %H:%M')
fi

init_user_sources >/dev/null 2>&1

get_all_sources >/dev/null 2>&1

dialog --no-shadow --infobox "\n$ENHANCIFY_ART\n\nModifier     : Graywizard888\nLast Updated : $LAST_UPDATED\nStatus       : $ONLINE_STATUS\nBuild Version: Enhanced V2.7.2\nRelease      : ${VERSION}" 14 45
sleep 3

tput civis

# True if the given aapt2 binary can be executed (aapt2 may print its version yet exit non-zero, so check the text too).
aapt2Runs() {
    local out
    out=$("$1" version 2>&1) && return 0
    [[ "$out" == *"Asset Packaging Tool"* ]]
}

# Pick a runnable aapt2: the bundled one, else the packaged one (e.g. Shellterm cannot run the bundled non-PIE binary).
# Result is cached in AAPT2_BIN; the packaged aapt2 is installed on demand and used in place (nothing is replaced).
resolveAapt2() {
    [ -n "$AAPT2_BIN" ] && return 0
    local bundled="$HOME/Enhancify/bin/aapt2"
    if aapt2Runs "$bundled"; then
        AAPT2_BIN="$bundled"
    elif aapt2Runs "$PREFIX/bin/aapt2"; then
        AAPT2_BIN="$PREFIX/bin/aapt2"
    else
        notify info "Bundled aapt2 cannot run here.\nInstalling packaged aapt2..."
        yes | pkg install aapt2 &>/dev/null
        aapt2Runs "$PREFIX/bin/aapt2" || return 1
        AAPT2_BIN="$PREFIX/bin/aapt2"
    fi
    return 0
}
