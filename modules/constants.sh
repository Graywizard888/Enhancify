#!/usr/bin/bash

STORAGE="$HOME/storage/shared/Enhancify"
VERSION="$HOME/Enhancify/.info"

if [ -f "$VERSION" ]; then
    source "$VERSION"
fi

ARCH=$(getprop ro.product.cpu.abi)
DPI=$(getprop ro.sf.lcd_density)

USER_AGENT="APKUpdater-3.0.3"

ROOT_STATUS=$(if [ "$(id -u)" -eq 0 ]; then echo 'Root Mode'; else echo 'Non-Root Mode'; fi)

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

DIALOG=(dialog --backtitle "Enhancify | $ROOT_STATUS | $ONLINE_STATUS | Arch: $ARCH" --no-shadow --begin 2 0)

CURL=(curl -sL --fail-early --connect-timeout 2 --max-time 5 -H 'Cache-Control: no-cache')

WGET=(wget -qc --show-progress --user-agent="$USER_AGENT")

NAVIGATION_HINT="Navigate with [↑] [↓] [←] [→]"
SELECTION_HINT="Select with [SPACE]"

source .config

[ "$GREEN_THEME" == "on" ] && THEME="GREEN" || THEME="DARK"
export DIALOGRC="config/.DIALOGRC_$THEME"

ENHANCIFY_ART="   ____     __                 _ ___    \n  / __/__  / /  ___ ____  ____(_) _/_ __\n / _// _ \/ _ \/ _ \`/ _ \\/ __/ / _/ // /\n/___/_//_/_//_/\\_,_/_//_/\\__/_/_/ \\_, / \n                                 /___/  "

dialog --keep-window --no-shadow --keep-window --infobox "\n$ENHANCIFY_ART\n\nModifier     : Graywizard888\nLast Updated : Checking...\nStatus       : Checking..." 13 45
sleep 3

if $GITHUB_REACHABLE; then
    git pull >/dev/null 2>&1 || (git fetch --all >/dev/null 2>&1 && git reset --hard "@{u}" >/dev/null 2>&1)
    LAST_UPDATED=$(git log -1 --pretty='format:%cd' --date=format:'%b %d, %Y | %H:%M')
else
    LAST_UPDATED=$(git log -1 --pretty='format:%cd' --date=format:'%b %d, %Y | %H:%M')
fi

dialog --no-shadow --infobox "\n$ENHANCIFY_ART\n\nModifier     : Graywizard888\nLast Updated : $LAST_UPDATED\nStatus       : $ONLINE_STATUS\nBuild Version: Enhanced V2.7.2\nRelease      : ${VERSION}" 14 45
sleep 3

if ! $APKMIRROR_REACHABLE; then
    dialog --msgbox "apkmirror.com is not reachable..\nUse Windscribe App VPN with stealth mode." 14 45
fi

tput civis
