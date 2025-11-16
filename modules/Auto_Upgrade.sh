#!/bin/bash
auto_update() {
    local target_pkgs=("wget" "ncurses-utils" "dialog" "pup" "jq" "aria2" "unzip" "zip" "apksigner")

    notify info "Starting dependency packages versions check ..\nThis process May Take Some Time..."
    pkg update >/dev/null 2>&1

    local upgradable
    upgradable=$(apt -qq list --upgradable 2>/dev/null | cut -d'/' -f1)

    if [ -z "$upgradable" ]; then
        notify msg "All packages are up to date"
        return 0
    fi

    local to_upgrade=()
    for pkg in "${target_pkgs[@]}"; do
        if grep -qw "^$pkg$" <<< "$upgradable"; then
            to_upgrade+=("$pkg")
        fi
    done

    if [ ${#to_upgrade[@]} -gt 0 ]; then
        notify info "Upgrading packages: ${to_upgrade[*]}"
        pkg install -y "${to_upgrade[@]}" >/dev/null 2>&1
        notify msg "Upgrade complete!"
    else
        notify msg "No updates available for dependency packages"
    fi
}
