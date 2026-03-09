bundleParser() {
    local SOURCES_FILE="$HOME/Enhancify/bundle_patcher_sources.json"
    [ -f "$SOURCES_FILE" ] || echo '{}' > "$SOURCES_FILE"

    local BUNDLE_FILE=""
    local bundle_mode=""

    while true; do
        BUNDLE_FILE=""
        bundle_mode=""

        local choice
        choice=$("${DIALOG[@]}" \
            --begin 2 0 \
            --title '| Bundle Patcher |' \
            --ok-label "Select" \
            --cancel-label "Back" \
            --menu "\nSelect an option:" \
            -1 -1 3 \
            "1" "Import from URL" \
            "2" "Import from JSON File" \
            "3" "Sources" \
            2>&1 >/dev/tty)

        [ $? -ne 0 ] && return 1

        case "$choice" in
            1)
                local input_url
                input_url=$("${DIALOG[@]}" \
                    --begin 2 0 \
                    --title '| Import from URL |' \
                    --ok-label "Next" \
                    --cancel-label "Back" \
                    --inputbox "\nEnter Bundle JSON URL:\n(Must start with https://raw.githubusercontent.com/ and end with .json)" \
                    -1 -1 "" \
                    2>&1 >/dev/tty)

                [ $? -ne 0 ] && continue

                input_url=$(echo "$input_url" | xargs)

                if [[ ! "$input_url" =~ ^https://raw\.githubusercontent\.com/.+\.json$ ]]; then
                    notify msg "URL Validation Failed\nCheck Entered URL\n\nURL must start with:\nhttps://raw.githubusercontent.com/\nand end with .json"
                    continue
                fi

                local test_tmp="$HOME/Enhancify/.url_test_tmp.json"
                if ! "${CURL[@]}" -sL -o "$test_tmp" "$input_url" 2>/dev/null; then
                    notify msg "URL Validation Failed\nCheck Entered URL\n\nFailed to download from URL."
                    rm -f "$test_tmp"
                    continue
                fi

                if [ ! -s "$test_tmp" ] || ! jq empty "$test_tmp" 2>/dev/null; then
                    notify msg "URL Validation Failed\nCheck Entered URL\n\nURL does not return valid JSON."
                    rm -f "$test_tmp"
                    continue
                fi

                local test_version test_download_url
                test_version=$(jq -r '.version // empty' "$test_tmp" 2>/dev/null)
                test_download_url=$(jq -r '.download_url // empty' "$test_tmp" 2>/dev/null)

                if [ -z "$test_version" ] || [ -z "$test_download_url" ]; then
                    notify msg "URL Validation Failed\nCheck Entered URL\n\nJSON missing required fields (version or download_url)."
                    rm -f "$test_tmp"
                    continue
                fi
                rm -f "$test_tmp"

                local url_filename
                url_filename=$(basename "$input_url" .json)

                local url_source_name="$url_filename"
                url_source_name="${url_source_name%-morphed-latest-patches-bundle}"
                url_source_name="${url_source_name%-morphed-stable-patches-bundle}"
                url_source_name="${url_source_name%-morphed-dev-patches-bundle}"
                url_source_name="${url_source_name%-latest-patches-bundle}"
                url_source_name="${url_source_name%-stable-patches-bundle}"
                url_source_name="${url_source_name%-dev-patches-bundle}"

                if [ -z "$url_source_name" ] || [ "$url_source_name" == "$url_filename" ]; then
                    url_source_name="$url_filename"
                fi

                local tmp_sources
                tmp_sources=$(jq --arg name "$url_source_name" --arg url "$input_url" \
                    '.[$name] = $url' "$SOURCES_FILE" 2>/dev/null)

                if [ -n "$tmp_sources" ]; then
                    echo "$tmp_sources" > "$SOURCES_FILE"
                    notify msg "Source '$url_source_name' saved successfully!\n\nYou can now use it from 'Sources' menu."
                else
                    notify msg "Failed to save source!"
                fi
                continue
                ;;

            2)
                local internalStorage="$HOME/storage/shared"
                [ -d "$internalStorage" ] || internalStorage="$HOME"
                local currentPath="$internalStorage"
                local newPath=""
                local exitstatus=0

                while [ ! -f "$newPath" ]; do
                    currentPath=${currentPath:-$internalStorage}
                    local dirList=()
                    local files=()
                    local num=0

                    while read -r itemName; do
                        if [ -d "$currentPath/$itemName" ]; then
                            files+=("$itemName")
                            local itemNameDisplay="$itemName"
                            [ "${#itemName}" -gt $(("$(tput cols)" - 24)) ] &&
                                itemNameDisplay="${itemName:0:$(("$(tput cols)" - 34))}...${itemName: -10}"
                            dirList+=("$((++num))" "$itemNameDisplay/" "DIR: $itemName/")
                        elif [[ "${itemName,,}" =~ \.json$ ]]; then
                            files+=("$itemName")
                            local itemNameDisplay="$itemName"
                            [ "${#itemName}" -gt $(("$(tput cols)" - 24)) ] &&
                                itemNameDisplay="${itemName:0:$(("$(tput cols)" - 34))}...${itemName: -10}"
                            dirList+=("$((++num))" "$itemNameDisplay" "FILE: $itemName")
                        fi
                    done < <(LC_ALL=C ls -1 --group-directories-first "$currentPath" 2>/dev/null)

                    if [ ${#dirList[@]} -eq 0 ]; then
                        dirList+=("1" "Directory Empty" "No files or subdirectories")
                    fi

                    local pathIndex
                    pathIndex=$("${DIALOG[@]}" \
                        --begin 2 0 \
                        --title '| Import Bundle - Select JSON File |' \
                        --item-help \
                        --ok-label "Select" \
                        --cancel-label "Back" \
                        --menu "Use arrow keys to navigate\nCurrent Path: $currentPath/" \
                        $(( $(tput lines) - 3 )) -1 15 \
                        "${dirList[@]}" \
                        2>&1 >/dev/tty)

                    exitstatus=$?
                    [ "$exitstatus" -eq 1 ] && break

                    if [[ "${dirList[$(($pathIndex*3-1))]}" == "Directory Empty" ]]; then
                        continue
                    fi

                    newPath="${files[$pathIndex-1]}"
                    newPath="$currentPath/$newPath"

                    if [ -d "$newPath" ]; then
                        currentPath="$newPath"
                        newPath=""
                    fi
                done

                [ "$exitstatus" -eq 1 ] && continue

                BUNDLE_FILE="$newPath"
                bundle_mode="file"
                ;;

            3)
                local source_names=()
                local source_urls=()
                local sourceList=()
                local snum=0

                while IFS=$'\t' read -r sname surl; do
                    source_names+=("$sname")
                    source_urls+=("$surl")
                    sourceList+=("$((++snum))" "$sname")
                done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$SOURCES_FILE" 2>/dev/null)

                if [ ${#sourceList[@]} -eq 0 ]; then
                    notify msg "No saved sources found!\nImport a URL first."
                    continue
                fi

                local sourceIndex
                sourceIndex=$("${DIALOG[@]}" \
                    --begin 2 0 \
                    --title '| Bundle Patcher - Sources |' \
                    --ok-label "Download" \
                    --cancel-label "Back" \
                    --menu "\nSaved Sources:" \
                    -1 -1 15 \
                    "${sourceList[@]}" \
                    2>&1 >/dev/tty)

                [ $? -ne 0 ] && continue

                local selected_source="${source_names[$sourceIndex-1]}"
                local selected_url="${source_urls[$sourceIndex-1]}"

                SOURCE="$selected_source"

                notify info "Downloading bundle JSON for '$selected_source'..."
                local temp_bundle="$HOME/Enhancify/${selected_source}-bundle.json"

                if ! "${CURL[@]}" -sL -o "$temp_bundle" "$selected_url" 2>/dev/null; then
                    notify msg "Failed to download bundle JSON!\nCheck your network and URL."
                    continue
                fi

                if [ ! -s "$temp_bundle" ] || ! jq empty "$temp_bundle" 2>/dev/null; then
                    notify msg "Downloaded file is invalid or empty!\nCheck the URL."
                    rm -f "$temp_bundle"
                    continue
                fi

                BUNDLE_FILE="$temp_bundle"
                bundle_mode="source"
                ;;
        esac

        [ -n "$BUNDLE_FILE" ] && break
    done

    [ -z "$BUNDLE_FILE" ] && return 1

    if [ "$bundle_mode" == "file" ]; then
        local bundle_basename
        bundle_basename=$(basename "$BUNDLE_FILE" .json)

        local source_name="$bundle_basename"
        source_name="${source_name%-morphed-latest-patches-bundle}"
        source_name="${source_name%-morphed-stable-patches-bundle}"
        source_name="${source_name%-morphed-dev-patches-bundle}"
        source_name="${source_name%-latest-patches-bundle}"
        source_name="${source_name%-stable-patches-bundle}"
        source_name="${source_name%-dev-patches-bundle}"

        if [ -z "$source_name" ] || [ "$source_name" == "$bundle_basename" ]; then
            source_name="$bundle_basename"
        fi

        SOURCE="$source_name"
    fi

    notify info "Processing Bundle MetaData"

    local bundle_version bundle_description bundle_created_at bundle_download_url bundle_sig_url
    bundle_version=$(jq -r '.version // empty' "$BUNDLE_FILE" 2>/dev/null)
    bundle_description=$(jq -r '.description // empty' "$BUNDLE_FILE" 2>/dev/null)
    bundle_created_at=$(jq -r '.created_at // empty' "$BUNDLE_FILE" 2>/dev/null)
    bundle_download_url=$(jq -r '.download_url // empty' "$BUNDLE_FILE" 2>/dev/null)
    bundle_sig_url=$(jq -r '.signature_download_url // empty' "$BUNDLE_FILE" 2>/dev/null)

    if [ -z "$bundle_version" ] || [ -z "$bundle_download_url" ]; then
        notify msg "Invalid bundle file!\nMissing required fields (version or download_url)."
        return 1
    fi

    bundle_description=$(printf '%b' "$bundle_description")

    bundle_description=$(echo "$bundle_description" | \
        sed -E 's/\[([^]]*)\]\(https?:\/\/[^)]*\)/\1/g' | \
        sed -E 's/https?:\/\/[^[:space:]]*//g' | \
        sed -E 's/\( *\)//g' | \
        sed -E 's/  +/ /g')

    bundle_description=$(printf '%s' "$bundle_description" | cat -s)

    bundle_description=$(printf '%s' "$bundle_description" | \
        sed '/./,$!d' | \
        sed -e :a -e '/^\s*$/{ $d; N; ba; }')

    bundle_description=$(printf '%s' "$bundle_description" | \
        sed -E 's/^#{1,6}\s*//g' | \
        sed -E 's/\*{1,2}([^*]+)\*{1,2}/\1/g')

    bundle_description=$(printf '%s' "$bundle_description" | \
        sed -E '/^={2,}$/d')

    "${DIALOG[@]}" \
        --title '| Bundle Details |' \
        --yes-label "Download" \
        --no-label "Back" \
        --yesno "\nSource     : $SOURCE\n\nVersion    : $bundle_version\n\nCreated At : ${bundle_created_at:-N/A}\n\nDescription:\n${bundle_description:-N/A}\n" -1 -1

    [ $? -ne 0 ] && return 1

    local PATCHES_EXT
    case "$bundle_download_url" in
        *.mpp) PATCHES_EXT="mpp" ;;
        *.rvp) PATCHES_EXT="rvp" ;;
        *)     PATCHES_EXT="mpp" ;;
    esac

    rm -f "$HOME/Enhancify/github_api_log.json"

    unset CLI_VERSION CLI_URL CLI_SIZE PATCHES_VERSION PATCHES_URL PATCHES_SIZE JSON_URL
    for var in $(compgen -v | grep "^ASSET_"); do
        unset "$var"
    done

    local GITHUB_TOKEN AUTH_HEADER AUTH_TEXT
    GITHUB_TOKEN=$(read_github_token)
    AUTH_HEADER=""
    AUTH_TEXT=""

    if [ -n "$GITHUB_TOKEN" ]; then
        AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
        AUTH_TEXT="[Authorised]"
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
        notify info "Initiating Network Acceleration ...\nFetching Bundle Assets for '$SOURCE'... $AUTH_TEXT"
    else
        notify info "Fetching Bundle Assets for '$SOURCE'... $AUTH_TEXT"
    fi

    "${CURL_CMD[@]}" "https://api.github.com/rate_limit" > response.tmp
    local response_headers=$(<headers.tmp)
    log_github_api_request "https://api.github.com/rate_limit" "$response_headers"
    local remaining
    remaining=$(jq -r '.resources.core.remaining' response.tmp 2>/dev/null)
    rm -f headers.tmp response.tmp

    if [ -z "$remaining" ] || [ "$remaining" -le 1 ]; then
        notify msg "Unable to proceed.\nYou are probably rate-limited at this moment.\nTry again later or use a GitHub token."
        return 1
    fi

    if [ "$bundle_mode" == "source" ] && [ -f "$BUNDLE_FILE" ]; then
        rm -f "$BUNDLE_FILE" 2>/dev/null
    fi

    rm -rf assets 2>/dev/null
    mkdir -p "assets/$SOURCE"
    rm -f "assets/$SOURCE/.data" "assets/.data" 2>/dev/null

    if [[ "$bundle_download_url" != https://github.com/* ]]; then
        notify msg "Invalid download URL format.\nExpected GitHub release URL.\n\nGot: $bundle_download_url"
        return 1
    fi

    local url_path="${bundle_download_url#https://github.com/}"
    local repo_owner repo_name release_tag
    repo_owner=$(echo "$url_path" | cut -d'/' -f1)
    repo_name=$(echo "$url_path" | cut -d'/' -f2)
    release_tag=$(echo "$url_path" | cut -d'/' -f5)

    if [ -z "$repo_owner" ] || [ -z "$repo_name" ] || [ -z "$release_tag" ]; then
        notify msg "Failed to parse download URL.\nExpected format:\nhttps://github.com/owner/repo/releases/download/tag/file"
        return 1
    fi

    local PATCHES_API_URL="https://api.github.com/repos/$repo_owner/$repo_name/releases/tags/$release_tag"

    notify info "Fetching Patches Release Info for '$SOURCE'... $AUTH_TEXT"

    "${CURL_CMD[@]}" "$PATCHES_API_URL" > response.tmp
    response_headers=$(<headers.tmp)
    log_github_api_request "$PATCHES_API_URL" "$response_headers"

    local detected_ext
    detected_ext=$(get_patches_extension_from_api "response.tmp")
    [ -n "$detected_ext" ] && PATCHES_EXT="$detected_ext"

    if ! jq -r --arg ext "$PATCHES_EXT" '
        if type == "array" then .[0] else . end |
        "PATCHES_VERSION='\''\(.tag_name)'\''",
        "PATCHES_EXT='\''" + $ext + "'\''",
        (
            .assets[] |
            select(
                (.name | endswith(".asc") | not) and
                (.name | endswith(".json") | not)
            ) |
            if (.name | endswith("." + $ext)) then
                "PATCHES_URL='\''\(.browser_download_url)'\''",
                "PATCHES_SIZE='\''\(.size|tostring)'\''"
            else
                "ASSET_URL_\(.name | gsub("[^a-zA-Z0-9_]"; "_"))='\''\(.browser_download_url)'\''",
                "ASSET_SIZE_\(.name | gsub("[^a-zA-Z0-9_]"; "_"))='\''\(.size|tostring)'\''",
                "ASSET_NAME_\(.name | gsub("[^a-zA-Z0-9_]"; "_"))='\''\(.name)'\''"
            end
        )
    ' response.tmp > "assets/$SOURCE/.data" 2>/dev/null; then
        rm -f headers.tmp response.tmp
        notify msg "Unable to fetch patches info from API!\nCheck the download URL and retry."
        return 1
    fi
    rm -f headers.tmp response.tmp

    source "assets/$SOURCE/.data"

    if [ -z "$PATCHES_URL" ] || [ -z "$PATCHES_SIZE" ] || [ "$PATCHES_SIZE" == "0" ]; then
        notify msg "Unable to determine patches file size.\nCheck the download URL and retry."
        return 1
    fi

    local CLI_API_URL
    if [ "$PATCHES_EXT" == "mpp" ]; then
        if [ "$USE_PRE_RELEASE" == "on" ]; then
            CLI_API_URL="https://api.github.com/repos/MorpheApp/morphe-cli/releases"
        else
            CLI_API_URL="https://api.github.com/repos/MorpheApp/morphe-cli/releases/latest"
        fi
    else
        if [ "$USE_PRE_RELEASE" == "on" ]; then
            CLI_API_URL="https://api.github.com/repos/inotia00/revanced-cli/releases"
        else
            CLI_API_URL="https://api.github.com/repos/inotia00/revanced-cli/releases/latest"
        fi
    fi

    notify info "Fetching CLI Info... $AUTH_TEXT"

    "${CURL_CMD[@]}" "$CLI_API_URL" > response.tmp
    response_headers=$(<headers.tmp)
    log_github_api_request "$CLI_API_URL" "$response_headers"

    if ! jq -r '
        if type == "array" then .[0] else . end |
        "CLI_VERSION='\''\(.tag_name)'\''",
        (
            .assets[] |
            if (.name | endswith(".jar")) then
                "CLI_URL='\''\(.browser_download_url)'\''",
                "CLI_SIZE='\''\(.size|tostring)'\''"
            else
                empty
            end
        )
    ' response.tmp > assets/.data 2>/dev/null; then
        rm -f headers.tmp response.tmp
        notify msg "Unable to fetch CLI info from API!\nRetry later."
        return 1
    fi
    rm -f headers.tmp response.tmp

    source "assets/.data"

    if [ -z "$CLI_VERSION" ] || [ -z "$CLI_URL" ] || [ -z "$CLI_SIZE" ]; then
        notify msg "Failed to parse CLI release info!\nRetry later."
        return 1
    fi

    PATCHES_FILE="assets/$SOURCE/Patches-$PATCHES_VERSION.$PATCHES_EXT"
    [ -e "$PATCHES_FILE" ] || rm -f assets/"$SOURCE"/Patches-* 2>/dev/null

    CLI_FILE="assets/CLI-$CLI_VERSION.jar"
    [ -e "$CLI_FILE" ] || rm -f assets/CLI-* 2>/dev/null

    local -a dl_urls dl_dirs dl_files dl_sizes dl_labels
    collectPendingDownloads

    if [ ${#dl_urls[@]} -gt 0 ]; then
        if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
            downloadBatchAria2c dl_urls dl_dirs dl_files dl_sizes dl_labels || return 1
        else
            downloadSequentialWget dl_urls dl_dirs dl_files dl_sizes dl_labels || return 1
        fi
    fi

    parsePatchesJson || return 1

    TASK="CHOOSE_APP"
    while true; do
        case "$TASK" in
            "CHOOSE_APP")
                chooseApp || break
                ;;
            "DOWNLOAD_APP")
                downloadApp || continue
                TASK="MANAGE_PATCHES"
                ;;
            "IMPORT_APP")
                importApp || continue
                TASK="MANAGE_PATCHES"
                ;;
            "MANAGE_PATCHES")
                managePatches || continue
                TASK="EDIT_OPTIONS"
                ;;
            "EDIT_OPTIONS")
                editOptions || continue
                TASK="PATCH_APP"
                ;;
            "PATCH_APP")
                patchApp || break
                TASK="INSTALL_APP"
                ;;
            "INSTALL_APP")
                installApp
                break
                ;;
        esac
    done
}
