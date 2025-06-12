#!/usr/bin/bash

STORAGE="$HOME/storage/shared/Enhancify"

ARCH=$(getprop ro.product.cpu.abi)
DPI=$(getprop ro.sf.lcd_density)

USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

ROOT_STATUS=$(if [ "$(id -u)" -eq 0 ]; then echo 'Root Mode'; else echo 'Non-Root Mode'; fi)

ONLINE_STATUS=$(if ping -c 1 google.com &> /dev/null; then echo 'Online'; else echo 'Offline'; fi)

DIALOG=(dialog --backtitle "Enhancify | $ROOT_STATUS | $ONLINE_STATUS | Arch: $ARCH" --no-shadow --begin 2 0)

CURL=(curl -sL --fail-early --connect-timeout 2 --max-time 5 -H 'Cache-Control: no-cache')

WGET=(wget -qc --show-progress --user-agent="$USER_AGENT")

NAVIGATION_HINT="Navigate with [↑] [↓] [←] [→]"

SELECTION_HINT="Select with [SPACE]"

source .config

[ "$DARK_THEME" == "on" ] && THEME="DARK" || THEME="GREEN"
export DIALOGRC="config/.DIALOGRC_$THEME"

dialog --keep-window --no-shadow --keep-window --infobox "\n ___________      .__                         .__  _____       \n\_   _____/ ____ |  |__ _____    ____   ____ |__|/ ____\__.__.\n |    __)_ /    \|  |  \\\\__  \  /    \_/ ___\|  \   __<   |  |\n |        \   |  \   Y  \/ __ \|   |  \  \___|  ||  |  \___  |\n/_______  /___|  /___|  (____  /___|  /\___  >__||__|  / ____|\n        \/     \/     \/     \/     \/     \/          \/     \n\nModifier     : Graywizard888\nLast Updated : Checking...\nStatus       : Checking..." 15 80
sleep 3

if ping -c 1 google.com >/dev/null 2>&1; then
    status=${status:-Online}
else
    status=Offline
fi

if [ "$status" == "Online" ]; then
    git pull >/dev/null 2>&1 || (git fetch --all >/dev/null 2>&1 && git reset --hard "@{u}" >/dev/null 2>&1)
    dialog --no-shadow --infobox "\n ___________      .__                         .__  _____       \n\_   _____/ ____ |  |__ _____    ____   ____ |__|/ ____\__.__.\n |    __)_ /    \|  |  \\\\__  \  /    \_/ ___\|  \   __<   |  |\n |        \   |  \   Y  \/ __ \|   |  \  \___|  ||  |  \___  |\n/_______  /___|  /___|  (____  /___|  /\___  >__||__|  / ____|\n        \/     \/     \/     \/     \/     \/          \/     \n\nModifier     : Graywizard888\nLast Updated : $(git log -1 --pretty='format:%cd' --date=format:'%b %d, %Y | %H:%M')\nStatus       : $status\nBuild Version: Enhanced V2.7.1\nRelease      : v2.3.0 Rc1" 15 80
    sleep 4
else
    dialog --no-shadow --infobox "\n ___________      .__                         .__  _____       \n\_   _____/ ____ |  |__ _____    ____   ____ |__|/ ____\__.__.\n |    __)_ /    \|  |  \\\\__  \  /    \_/ ___\|  \   __<   |  |\n |        \   |  \   Y  \/ __ \|   |  \  \___|  ||  |  \___  |\n/_______  /___|  /___|  (____  /___|  /\___  >__||__|  / ____|\n        \/     \/     \/     \/     \/     \/          \/     \n\nModifier     : Graywizard888\nLast Updated : $(git log -1 --pretty='format:%cd' --date=format:'%b %d, %Y | %H:%M')\nStatus       : $status\nBuild Version: Enhanced V2.7.1\nRelease      : v2.3.0 Rc1" 15 80
    sleep 4
fi
tput civis
