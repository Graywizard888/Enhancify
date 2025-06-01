#!/usr/bin/bash

configure() {
    while true; do
        local MAIN_CHOICE
        MAIN_CHOICE=$("${DIALOG[@]}" \
            --title '| Settings |' \
            --cancel-label 'Back' \
            --ok-label 'Select' \
            --menu "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
            "Toggle Options" "Modify toggle settings" \
            "Custom Sources" "Manage custom sources" \
            2>&1 > /dev/tty)

        case $MAIN_CHOICE in
            "Toggle Options")
                toggle_options
                ;;
            "Custom Sources")
                custom_source_management
                ;;
            *)
                break
                ;;
        esac
    done
}

toggle_options() {
    local CONFIG_OPTS UPDATED_CONFIG THEME
    CONFIG_OPTS=("DARK_THEME" "$DARK_THEME" "PREFER_SPLIT_APK" "$PREFER_SPLIT_APK" "LAUNCH_APP_AFTER_MOUNT" "$LAUNCH_APP_AFTER_MOUNT" "ALLOW_APP_VERSION_DOWNGRADE" "$ALLOW_APP_VERSION_DOWNGRADE" "USE_PRE_RELEASE" "$USE_PRE_RELEASE")

    readarray -t UPDATED_CONFIG < <(
        "${DIALOG[@]}" \
            --title '| Toggle Options |' \
            --no-items \
            --separate-output \
            --no-cancel \
            --ok-label 'Save' \
            --checklist "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
            "${CONFIG_OPTS[@]}" \
            2>&1 > /dev/tty
    )

    sed -i "s|='on'|='off'|" .config

    for CONFIG_OPT in "${UPDATED_CONFIG[@]}"; do
        setEnv "$CONFIG_OPT" on update .config
    done

    source .config

    [ "$DARK_THEME" == "on" ] && THEME="DARK" || THEME="GREEN"
    export DIALOGRC="config/.DIALOGRC_$THEME"
}

custom_source_management() {
    while true; do
        local SOURCE_CHOICE
        SOURCE_CHOICE=$("${DIALOG[@]}" \
            --title '| Custom Source Management |' \
            --no-cancel \
            --ok-label 'Select' \
            --menu "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
            "Add Source" "Add new custom source (Experimental)" \
            "Description" "How to add sources" \
            "Back" "Return to main menu" \
            2>&1 > /dev/tty)

        case $SOURCE_CHOICE in
            "Add Source")
                add_custom_source
                ;;
            "Description")
                show_source_help
                ;;
            "Back")
                break
                ;;
        esac
    done
}

add_custom_source() {
    local SOURCE_NAME REPO_NAME JSON_URL VERSION

    while true; do
        # Input dialogs with validation
        SOURCE_NAME=$("${DIALOG[@]}" --title "Source Name" --inputbox "Enter source name (required):" -1 -1 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return  # Cancel pressed
        [ -z "$SOURCE_NAME" ] && notify msg "Source name cannot be empty!" && continue

        REPO_NAME=$("${DIALOG[@]}" --title "Repository" --inputbox "Enter repository (username/repo) (required):" -1 -1 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return
        if [ -z "$REPO_NAME" ]; then
            notify msg "Repository cannot be empty!"
            continue
        fi
        if [[ ! "$REPO_NAME" =~ ^[^/]+/[^/]+$ ]]; then
            notify msg "Invalid repository format! Must be: username/repo"
            continue
        fi

        JSON_URL=$("${DIALOG[@]}" --title "JSON URL (Optional)" --inputbox "Enter JSON URL (leave blank for null):" -1 -1 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return

        VERSION=$("${DIALOG[@]}" --title "Version (Optional)" --inputbox "Enter version (leave blank for null):" -1 -1 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return

        break  # All inputs valid, exit loop
    done

    # Handle empty values
    [ -z "$JSON_URL" ] && JSON_URL="null"
    [ -z "$VERSION" ] && VERSION="null"

    # Create JSON structure with jq
    jq --arg source "$SOURCE_NAME" \
       --arg repo "$REPO_NAME" \
       --arg json "$JSON_URL" \
       --arg version "$VERSION" \
       '. += [{
            "source": $source,
            "repository": $repo,
            "api": {
                "json": (if $json == "null" then null else $json end),
                "version": (if $version == "null" then null else $version end)
            }
        }]' sources.json > temp.json && mv temp.json sources.json

    notify msg "Custom source added successfully!"
}

show_source_help() {
    local HELP_MSG="WARNING!! this feature is in experimental phase may sometime work may not..

To add a custom source, you need to provide details in sources.json format:-

1. Source Name: project name.

2. Repository: example Aunali321/RevancedExperiments (username/projectname)

3. JSON URL (Optional): URL of patches.json file found on github source code repo ask developers so they can assist adding this increases the sucess rate of fetching patches.

4. Version (Optional): Enter Source version if you like.

Leave optional fields blank to set them to null"

    "${DIALOG[@]}" --msgbox "$HELP_MSG" -1 -1
}
