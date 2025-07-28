add_github_token() {
    local ENHANCIFY_DIR="$(dirname "$0")"
    local TOKEN_FILE="$ENHANCIFY_DIR/github_token.json"

    if ! command -v jq &> /dev/null; then
        notify msg "ERROR: 'jq' is required but not installed.\n\nPlease install jq to use this feature."
        return 1
    fi

    while true; do

        local TOKEN_INPUT=$("${DIALOG[@]}" \
            --title 'Add custom token' \
            --no-cancel  \
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
            return 0
        else
            notify msg "Failed to save token!"
        fi
    done
}
