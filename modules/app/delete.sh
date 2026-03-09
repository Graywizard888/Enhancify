#!/usr/bin/bash

deleteApps() {
    while true; do
        choice=$("${DIALOG[@]}" \
            --title '| Apps Storage Manager |' \
            --ok-label "Select" \
            --cancel-label "Back" \
            --menu "Choose an option:" -1 -1 3 \
            1 "Delete Internal Storage saved APKs" \
            2 "Delete Terminal Saved APKs" \
            3 "Delete All Saved APKs" \
            3>&1 1>&2 2>&3)

        case $? in
            1|255) return ;;
        esac

        case "$choice" in
            1)
                if "${DIALOG[@]}" \
                    --title '| Confirm Deletion |' \
                    --defaultno \
                    --yesno "Are you sure you want to delete all Internal Storage patched APKs?" -1 -1; then
                    rm -rf "$STORAGE"/Patched/* &> /dev/null
                fi
                ;;
            2)
                if "${DIALOG[@]}" \
                    --title '| Confirm Deletion |' \
                    --defaultno \
                    --yesno "Are you sure you want to delete all Terminal stock/patched APKs?" -1 -1; then
                    rm -rf "apps"/* &> /dev/null
                fi
                ;;
            3)
                if "${DIALOG[@]}" \
                    --title '| Confirm Deletion |' \
                    --defaultno \
                    --yesno "Are you sure you want to delete ALL saved APKs?\n\nThis will delete all stock/patched apks \n\nThis action cannot be undone!" -1 -1; then
                    rm -rf "$STORAGE"/Patched/* "apps"/* &> /dev/null
                fi
                ;;
        esac
    done
}
