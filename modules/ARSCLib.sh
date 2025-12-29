#!/usr/bin/bash

arsclib() {
    # Part 1: Show source selection dialog
    if ! "${DIALOG[@]}" \
        --title '| Select Source |' \
        --ok-label "Select" \
        --cancel-label "Back" \
        --menu "Choose patch source:" -1 -1 1 \
        "1" "inotia00 reddit" \
        2>&1 >/dev/tty; then
        return 1
    fi

    # Part 2: Download CLI, Patches, and Integrations
    local PATCH_DIR="$HOME/Enhancify/patch"
    local STORAGE="$HOME/Enhancify"
    local GITHUB_TOKEN
    GITHUB_TOKEN=$(read_github_token)
    local AUTH_HEADER=""

    if [ -n "$GITHUB_TOKEN" ]; then
        AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
    fi

    local CURL_CMD=("${CURL[@]}" \
        --compressed \
        --retry 3 \
        --retry-delay 1 \
        -A "$USER_AGENT_GITHUB" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28")

    if [ -n "$AUTH_HEADER" ]; then
        CURL_CMD+=(-H "$AUTH_HEADER")
    fi

    CURL_CMD+=(-D headers.tmp)

    internet || return 1

    if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
        notify info "Initiating Network Acceleration ...\nFetching Assets Info..."
    else
        notify info "Fetching Assets Info..."
    fi

    local SKIP_DOWNLOAD=false
    local CLI_NAME PATCHES_NAME INTEGRATIONS_NAME

    # Check if patch directory exists and has required files
    if [ -d "$PATCH_DIR" ] && [ -n "$(ls -A "$PATCH_DIR" 2>/dev/null)" ]; then
        local cli_file=$(find "$PATCH_DIR" -maxdepth 1 -name "*.jar" -type f 2>/dev/null | grep -i "cli" | head -n 1)
        local patches_file=$(find "$PATCH_DIR" -maxdepth 1 -name "*.jar" -type f 2>/dev/null | grep -i "patch" | head -n 1)
        local integrations_file=$(find "$PATCH_DIR" -maxdepth 1 -name "*.apk" -type f 2>/dev/null | head -n 1)

        if [ -s "$cli_file" ] && [ -s "$patches_file" ] && [ -s "$integrations_file" ]; then
            notify info "Using existing patch files"
            CLI_NAME=$(basename "$cli_file")
            PATCHES_NAME=$(basename "$patches_file")
            INTEGRATIONS_NAME=$(basename "$integrations_file")
            SKIP_DOWNLOAD=true
        else
            rm -rf "$PATCH_DIR"
            mkdir -p "$PATCH_DIR"
        fi
    else
        mkdir -p "$PATCH_DIR"
    fi

    # Download files if needed
    if [ "$SKIP_DOWNLOAD" = false ]; then
        # Fetch and download CLI
        "${CURL_CMD[@]}" "https://api.github.com/repos/inotia00/revanced-cli-arsclib/releases/latest" > response.tmp
        response_headers=$(<headers.tmp)
        log_github_api_request "https://api.github.com/repos/inotia00/revanced-cli-arsclib/releases/latest" "$response_headers"

        local CLI_URL CLI_SIZE
        source <(jq -r '
            .assets[] |
            select(.name | endswith(".jar")) |
            "CLI_URL=\"\(.browser_download_url)\"",
            "CLI_SIZE=\"\(.size)\"",
            "CLI_NAME=\"\(.name)\""
        ' response.tmp)
        rm -f headers.tmp response.tmp

        if [ -z "$CLI_URL" ]; then
            notify msg "Failed to fetch CLI info from GitHub API"
            return 1
        fi

        local CTR=3
        while [ "$CLI_SIZE" != "$(stat -c %s "$PATCH_DIR/$CLI_NAME" 2>/dev/null)" ]; do
            [ $CTR -eq 0 ] && notify msg "Oops! Unable to download CLI completely.\n\nRetry or change your Network." && return 1
            ((CTR--))

            local cli_text="File    : $CLI_NAME\n"
            cli_text+="Size    : $(numfmt --to=iec --format="%0.1f" "$CLI_SIZE")\n"
            cli_text+="\nDownloading..."

            downloadFile "$CLI_URL" "$PATCH_DIR/$CLI_NAME" "$CLI_SIZE" "$cli_text"
            tput civis
        done

        if [ ! -s "$PATCH_DIR/$CLI_NAME" ]; then
            notify msg "Downloaded CLI file is empty or corrupted"
            return 1
        fi

        # Fetch and download Patches
        "${CURL_CMD[@]}" "https://api.github.com/repos/inotia00/revanced-patches-arsclib/releases/latest" > response.tmp
        response_headers=$(<headers.tmp)
        log_github_api_request "https://api.github.com/repos/inotia00/revanced-patches-arsclib/releases/latest" "$response_headers"

        local PATCHES_URL PATCHES_SIZE
        source <(jq -r '
            .assets[] |
            select(.name | endswith(".jar")) |
            "PATCHES_URL=\"\(.browser_download_url)\"",
            "PATCHES_SIZE=\"\(.size)\"",
            "PATCHES_NAME=\"\(.name)\""
        ' response.tmp)
        rm -f headers.tmp response.tmp

        if [ -z "$PATCHES_URL" ]; then
            notify msg "Failed to fetch Patches info from GitHub API"
            return 1
        fi

        CTR=3
        while [ "$PATCHES_SIZE" != "$(stat -c %s "$PATCH_DIR/$PATCHES_NAME" 2>/dev/null)" ]; do
            [ $CTR -eq 0 ] && notify msg "Oops! Unable to download Patches completely.\n\nRetry or change your Network." && return 1
            ((CTR--))

            local patches_text="File    : $PATCHES_NAME\n"
            patches_text+="Size    : $(numfmt --to=iec --format="%0.1f" "$PATCHES_SIZE")\n"
            patches_text+="\nDownloading..."

            downloadFile "$PATCHES_URL" "$PATCH_DIR/$PATCHES_NAME" "$PATCHES_SIZE" "$patches_text"
            tput civis
        done

        if [ ! -s "$PATCH_DIR/$PATCHES_NAME" ]; then
            notify msg "Downloaded Patches file is empty or corrupted"
            return 1
        fi

        # Fetch and download Integrations
        "${CURL_CMD[@]}" "https://api.github.com/repos/inotia00/revanced-integrations/releases/latest" > response.tmp
        response_headers=$(<headers.tmp)
        log_github_api_request "https://api.github.com/repos/inotia00/revanced-integrations/releases/latest" "$response_headers"

        local INTEGRATIONS_URL INTEGRATIONS_SIZE
        source <(jq -r '
            .assets[] |
            select(.name | endswith(".apk")) |
            "INTEGRATIONS_URL=\"\(.browser_download_url)\"",
            "INTEGRATIONS_SIZE=\"\(.size)\"",
            "INTEGRATIONS_NAME=\"\(.name)\""
        ' response.tmp)
        rm -f headers.tmp response.tmp

        if [ -z "$INTEGRATIONS_URL" ]; then
            notify msg "Failed to fetch Integrations info from GitHub API"
            return 1
        fi

        CTR=3
        while [ "$INTEGRATIONS_SIZE" != "$(stat -c %s "$PATCH_DIR/$INTEGRATIONS_NAME" 2>/dev/null)" ]; do
            [ $CTR -eq 0 ] && notify msg "Oops! Unable to download Integrations completely.\n\nRetry or change your Network." && return 1
            ((CTR--))

            local integrations_text="File    : $INTEGRATIONS_NAME\n"
            integrations_text+="Size    : $(numfmt --to=iec --format="%0.1f" "$INTEGRATIONS_SIZE")\n"
            integrations_text+="\nDownloading..."

            downloadFile "$INTEGRATIONS_URL" "$PATCH_DIR/$INTEGRATIONS_NAME" "$INTEGRATIONS_SIZE" "$integrations_text"
            tput civis
        done

        if [ ! -s "$PATCH_DIR/$INTEGRATIONS_NAME" ]; then
            notify msg "Downloaded Integrations file is empty or corrupted"
            return 1
        fi
    fi

    # Part 3: Import App
    unset PKG_NAME APP_NAME APP_VER
    local SELECTED_FILE FILE_PATH APP_EXT SELECTED_VERSION
    selectFile || return 1
    extractMeta || return 1
    APP_VER="${SELECTED_VERSION// /-}"

    if ! "${DIALOG[@]}" \
        --title '| App Details |' \
        --yes-label 'Import App' \
        --no-label 'Back' \
        --yesno "The following data is extracted from the file you provided.\nApp Name    : $APP_NAME\nPackage Name: $PKG_NAME\nVersion     : $SELECTED_VERSION\nDo you want to proceed with this app?" -1 -1; then
        return 1
    fi

    # Part 4: Create patches.json
    local PATCHES_JSON="$PATCH_DIR/patches.json"
    notify info "Loading patches list..."

    cat > "$PATCHES_JSON" << 'EOF'
[{"name":"Change installer package name","description":"Spoof the installer package name to make it appear that the app was installed from the App Store.","version":"0.0.0","excluded":false,"options":[{"key":"ChangeInstallerPackageName","title":"Change installer package name","description":"Spoof the installer package name.","required":true,"choices":null},{"key":"InstallerPackageName","title":"Installer package name","description":"The package name from which the app was installed, such as \u0027com.android.vending\u0027","required":true,"choices":null}],"dependencies":[],"compatiblePackages":[]},{"name":"Change version code","description":"Changes the version code of the app. By default the highest version code is set. This allows older versions of an app to be installed if their version code is set to the same or a higher value and can stop app stores to update the app. This does not apply when installing with root install (mount).","version":"0.0.0","excluded":false,"options":[{"key":"ChangeVersionCode","title":"Change version code","description":"Changes the version code of the app.","required":true,"choices":null},{"key":"VersionCode","title":"Version code","description":"The version code to use. (1 ~ 2147483647)","required":true,"choices":null}],"dependencies":[],"compatiblePackages":[]},{"name":"Custom branding name for Reddit","description":"Renames the Reddit app to the name specified in options.json.","version":"0.0.0","excluded":false,"options":[{"key":"AppName","title":"App name","description":"The name of the app.","required":true,"choices":null}],"dependencies":[],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Disable screenshot popup","description":"Adds an option to disable the popup that appears when taking a screenshot.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Hide Trending Today shelf","description":"Adds an option to hide the Trending Today shelf from search suggestions.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Hide ads","description":"Adds options to hide ads.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit","CommentAdsPatch"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Hide navigation buttons","description":"Adds options to hide buttons in the navigation bar.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Hide recommended communities shelf","description":"Adds an option to hide the recommended communities shelves in subreddits.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Hide sidebar components","description":"Adds options to hide the sidebar components.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Open links directly","description":"Adds an option to skip over redirection URLs in external links.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit","ScreenNavigatorMethodResolverPatch"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Open links externally","description":"Adds an option to always open links in your browser instead of in the in-app-browser.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit","ScreenNavigatorMethodResolverPatch"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Override certificate pinning","description":"Overrides certificate pinning, allowing to inspect traffic via a proxy.","version":"0.0.0","excluded":false,"options":[{"key":"OverrideCertificatePinning","title":"Override certificate pinning","description":"Overrides certificate pinning, allowing to inspect traffic via a proxy.","required":true,"choices":null}],"dependencies":[],"compatiblePackages":[]},{"name":"Remove subreddit dialog","description":"Adds options to remove the NSFW community warning and notifications suggestion dialogs by dismissing them automatically.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Sanitize sharing links","description":"Adds an option to remove tracking query parameters from URLs when sharing links.","version":"0.0.0","excluded":false,"options":[],"dependencies":["Settings for Reddit"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Settings for Reddit","description":"Applies mandatory patches to implement RVX settings into the application.","version":"0.0.0","excluded":false,"options":[{"key":"RVXSettingsMenuName","title":"RVX settings menu name","description":"The name of the RVX settings menu.","required":true,"choices":null}],"dependencies":["reddit-integrations","SettingsBytecodePatch"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]},{"name":"Spoof signature","description":"Spoofs the signature of the app.","version":"0.0.0","excluded":false,"options":[],"dependencies":["reddit-integrations"],"compatiblePackages":[{"name":"com.reddit.frontpage","versions":["2025.40.0","2025.43.0","2025.45.0","2025.52.0"]}]}]
EOF

    if [ ! -s "$PATCHES_JSON" ]; then
        notify msg "Failed to create patches.json"
        return 1
    fi

    # Build patches menu
    local patches_menu=()
    local patch_names=()
    local patch_index=0

    while IFS= read -r line; do
        local patch_name=$(jq -r '.name' <<< "$line")
        local patch_desc=$(jq -r '.description' <<< "$line")

        if [ ${#patch_desc} -gt 60 ]; then
            patch_desc="${patch_desc:0:57}..."
        fi

        patch_names+=("$patch_name")
        patches_menu+=("$patch_index" "$patch_name" "off" "$patch_desc")
        ((patch_index++))
    done < <(jq -c '.[]' "$PATCHES_JSON")

    # Show patches selection dialog
    local selected_indices
    selected_indices=$("${DIALOG[@]}" \
        --title '| Select Patches |' \
        --ok-label "Next" \
        --cancel-label "Back" \
        --item-help \
        --checklist "Select patches to apply:" \
        $(( $(tput lines) - 3 )) -1 15 \
        "${patches_menu[@]}" \
        2>&1 >/dev/tty)

    if [ $? -ne 0 ]; then
        return 1
    fi

    # Save selected patches
    local selected_patches_json="$STORAGE/selected_patches.json"
    local selected_names=()

    for index in $selected_indices; do
        selected_names+=("${patch_names[$index]}")
    done

    printf '%s\n' "${selected_names[@]}" | jq -R . | jq -s . > "$selected_patches_json"

    # Part 5: Start patching
    local SOURCE="arsclib"
    local patch_log="$STORAGE/patch_log.txt"
    rm -f "$patch_log"

    mkdir -p "$STORAGE/apps"

    local OUTPUT_APK="$HOME/Enhancify/apps/$APP_NAME"
    rm -f "$OUTPUT_APK"

    # Build patch command
    local patch_cmd="java -jar \"$PATCH_DIR/$CLI_NAME\""
    patch_cmd+=" -a \"$FILE_PATH\""
    patch_cmd+=" -o \"$OUTPUT_APK\""
    patch_cmd+=" -m \"$PATCH_DIR/$INTEGRATIONS_NAME\""
    patch_cmd+=" -b \"$PATCH_DIR/$PATCHES_NAME\""
    patch_cmd+=" --options=\"$STORAGE/options.json\""
    patch_cmd+=" --exclusive" \
    patch_cmd+=" --experimental" \
    patch_cmd+=" --clean"

    for patch_name in "${selected_names[@]}"; do
        patch_cmd+=" -i \"$patch_name\""
    done

    # Execute patching
    local EXIT_CODE=0
    eval "$patch_cmd" 2>&1 | tee -a "$patch_log" | \
        "${DIALOG[@]}" \
            --ok-label 'Install & Save' \
            --extra-button \
            --extra-label 'Share Logs' \
            --cursor-off-label \
            --programbox "Patching Reddit $APP_VER" -1 -1

    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 3 ]; then
        termux-open --send "$patch_log"
    fi

    if [ ! -f "apps/$APP_NAME/base.apk" ]; then
        notify msg "Patching failed !!\nInstallation Aborted."
        return 1
    fi

    if cp -f "apps/$APP_NAME/base.apk" "$HOME/storage/shared/Enhancify/Patched/Reddit-ARSClib.apk" &> /dev/null; then
        notify info "$APP_NAME Moved to Internal storage/Enhancify/Patched\n Preparing to install"
        sleep 1
        termux-open --view "$HOME/storage/shared/Enhancify/Patched/Reddit-ARSClib.apk"
    fi
}
