#!/bin/bash

CONFIG_FILE="$HOME/Enhancify/apkmirror_config.json"

initialize_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        echo '{"max_page_limit": 5}' > "$CONFIG_FILE"
    fi
}

apkmirror_management() {

    initialize_config
    
    while true; do
        choice=$(dialog \
            --backtitle "Enhancify" \
            --title "| apkmirror configurations |" \
            --ok-label "select" \
            --cancel-label "Back" \
            --menu "Choose configuration option:" -1 -1 -1 \
            1 "max page limit" \
            2>&1 >/dev/tty)

        exit_status=$?

        if [ $exit_status -ne 0 ]; then
            return 1
        fi

        case $choice in
            1)
                input=$(dialog \
                    --backtitle "Enhancify" \
                    --title "| max page limit |" \
                    --ok-label "save" \
                    --cancel-label "cancel" \
                    --inputbox "Enter page limit (default 5):" -1 -1 \
                    2>&1 >/dev/tty)

                input_status=$?

                if [ $input_status -ne 0 ]; then
                    continue
                fi

                if [[ "$input" =~ ^[0-9]+$ ]]; then
                    page_limit="$input"
                    is_valid=true
                else
                    page_limit=5
                    is_valid=false
                fi

                if jq --argjson limit "$page_limit" '.max_page_limit = $limit' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && \
                   mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"; then

                    if [ "$is_valid" = true ]; then
                        notify msg "apkmirror max page limit set to $page_limit"
                    else
                        notify msg "invalid input\noverrided to default 5"
                    fi
                else
                    notify msg "configurations invalid\ntry again"
                fi
                ;;
        esac
    done
}
