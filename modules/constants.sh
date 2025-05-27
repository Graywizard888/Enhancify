#!/usr/bin/bash

STORAGE="$HOME/storage/shared/Revancify"

ARCH=$(getprop ro.product.cpu.abi)
DPI=$(getprop ro.sf.lcd_density)

USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

ROOT_STATUS=$(if [ "$(id -u)" -eq 0 ]; then echo 'Root Mode'; else echo 'Non-Root Mode'; fi)

ONLINE_STATUS=$(if ping -c 1 google.com &> /dev/null; then echo 'Online'; else echo 'Offline'; fi)

DIALOG=(dialog --backtitle "Revancify Enhanced | $ROOT_STATUS | $ONLINE_STATUS | Arch: $ARCH" --no-shadow --begin 2 0)

CURL=(curl -sL --fail-early --connect-timeout 2 --max-time 5 -H 'Cache-Control: no-cache')

WGET=(wget -qc --show-progress --user-agent="$USER_AGENT")

NAVIGATION_HINT="Navigate with [↑] [↓] [←] [→]"

SELECTION_HINT="Select with [SPACE]"

source .config

    [ "$DARK_THEME" == "on" ] && THEME="DARK" || THEME="GREEN"
    export DIALOGRC="config/.DIALOGRC_$THEME"

dialog --keep-window --no-shadow --keep-window --infobox "\n  █▀█ █▀▀ █░█ ▄▀█ █▄░█ █▀▀ █ █▀▀ █▄█\n  █▀▄ ██▄ ▀▄▀ █▀█ █░▀█ █▄▄ █ █▀░ ░█░  \n\nModifier     : GrayWizard\nLast Updated : Checking...\nStatus       : Checking..." 10 42
sleep 3

if ping -c 1 google.com >/dev/null 2>&1; then
    status=${status:-Online}
else
    status=Offline
fi
if [ "$status" == "Online" ]; then
    git pull >/dev/null 2>&1 || (git fetch --all >/dev/null 2>&1 && git reset --hard "@{u}" >/dev/null 2>&1)
    dialog --no-shadow --infobox "\n  █▀█ █▀▀ █░█ ▄▀█ █▄░█ █▀▀ █ █▀▀ █▄█\n  █▀▄ ██▄ ▀▄▀ █▀█ █░▀█ █▄▄ █ █▀░ ░█░  \n\nModifier     : GrayWizard\nLast Updated : $(git log -1 --pretty='format:%cd' --date=format:'%b %d, %Y | %H:%M')\nStatus       : $status\nVersion      : Enhanced V2.7.0" 10 42
sleep 5

else
    dialog --no-shadow --infobox "\n  █▀█ █▀▀ █░█ ▄▀█ █▄░█ █▀▀ █ █▀▀ █▄█\n  █▀▄ ██▄ ▀▄▀ █▀█ █░▀█ █▄▄ █ █▀░ ░█░  \n\nModifier    : GrayWizard\nLast Updated : $(git log -1 --pretty='format:%cd' --date=format:'%b %d, %Y | %H:%M')\nStatus       : $status\nVersion      : Enhanced V2.7.0"  10 42
sleep 5
fi
tput civis
