github_token_management() {
    local ENHANCIFY_DIR="$(dirname "$0")"
    local TOKEN_FILE="$ENHANCIFY_DIR/github_token.json"

    if ! command -v jq &> /dev/null; then
        notify msg "ERROR: 'jq' is required but not installed.\n\nPlease install jq to use this feature."
        return 1
    fi

    while true; do
        local MENU_OPTIONS=(
            "1" "Add/Replace Custom token"
            "2" "Description"
        )
        [[ -f "$TOKEN_FILE" ]] && MENU_OPTIONS+=("3" "Delete custom token")

        local MENU_CHOICE
        MENU_CHOICE=$("${DIALOG[@]}" \
            --title '| Custom GitHub Token Management |' \
            --ok-label 'Select' \
            --cancel-label 'Back' \
            --menu 'Choose an option:' -1 -1 -1 \
            "${MENU_OPTIONS[@]}" \
            2>&1 > /dev/tty) || break

        case "$MENU_CHOICE" in
            1)
                while true; do
                    local TOKEN_INPUT=$("${DIALOG[@]}" \
                        --title '| Add/Replace custom token |' \
                        --no-cancel \
                        --ok-label 'Done' \
                        --inputbox "Enter GitHub classic token:  (ctrl+c) to exit" -1 -1 \
                        2>&1 > /dev/tty)

                    if [[ -z "${TOKEN_INPUT// }" ]]; then
                        notify msg "Token cannot be empty or whitespace!"
                        continue
                    fi

                    dialog --backtitle 'Enhancify' --defaultno \
                        --yesno "Do you want to use this token?" 12 45 \
                        2>&1 > /dev/tty || continue

                    if jq -n --arg token "$TOKEN_INPUT" '{token: $token}' > "$TOKEN_FILE"; then
                        chmod 600 "$TOKEN_FILE"
                        notify msg "Token Successfully Saved"
                        break
                    else
                        notify msg "Failed to save token!"
                    fi
                done
                ;;

            2)
                local GUIDE_TEXT="Guide:

1. Go To Github
2. Tap On Profile
3. Select Settings
4. Select Developer Settings
5. Tap Personal Access Token
6. Choose Token (Classic)
7. Generate New Token (Classic)
8. Expiration: Your Choice (Choose No Expiration for permanent)
9. Check Permissions:
   • public_repo
   • read:packages
   • read:projects
10. Tap Generate Token

NOTE :-
   • This Is Experimental Feature
   • Do Not Share Your Token With Anyone"

                "${DIALOG[@]}" \
                    --title '| Token Creation Guide |' \
                    --ok-label 'Understood' \
                    --msgbox "$GUIDE_TEXT" -1 -1 \
                    2>&1 > /dev/tty
                ;;

            3)
                dialog --backtitle 'Enhancify' --defaultno \
                    --yesno "Are you sure you want to delete the token?" 12 45 \
                    2>&1 > /dev/tty && {
                    rm -f "$TOKEN_FILE"
                    notify msg "Token Sucessfully deleted From Records"
                }
                ;;
        esac
    done
}
