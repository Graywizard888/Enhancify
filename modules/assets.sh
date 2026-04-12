#!/usr/bin/bash

read_github_token() {
    local token_file="$HOME/Enhancify/github_token.json"

    if [ -f "$token_file" ]; then
        local token
        token=$(jq -r '.token' "$token_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi
    return 1
}

log_github_api_request() {
    local endpoint="$1"
    local response_headers="$2"

    local limit remaining reset
    limit=$(grep -i 'x-ratelimit-limit:' <<< "$response_headers" | awk '{print $2}' | tr -d '\r')
    remaining=$(grep -i 'x-ratelimit-remaining:' <<< "$response_headers" | awk '{print $2}' | tr -d '\r')
    reset=$(grep -i 'x-ratelimit-reset:' <<< "$response_headers" | awk '{print $2}' | tr -d '\r')

    [ -z "$limit" ] && limit="0"
    [ -z "$remaining" ] && remaining="0"
    [ -z "$reset" ] && reset="0"

    local log_file="$HOME/Enhancify/github_api_log.json"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local log_entry
    log_entry=$(jq -n \
        --arg ts "$timestamp" \
        --arg ep "$endpoint" \
        --arg lim "$limit" \
        --arg rem "$remaining" \
        --arg res "$reset" \
        '{
            timestamp: $ts,
            endpoint: $ep,
            limit: $lim | tonumber,
            remaining: $rem | tonumber,
            reset: $res | tonumber
        }')

    if [ -f "$log_file" ]; then
        jq --argjson new "$log_entry" '. += [$new]' "$log_file" > tmp_log && mv tmp_log "$log_file"
    else
        echo "[$log_entry]" > "$log_file"
    fi
}

get_cached_cli() {
    local source="$1"
    local expected_version="$2"
    local target_file="$3"

    [ "$CACHE_CLI" != "on" ] && return 1

    local cache_dir="$HOME/Enhancify/cli_cache/$source"
    local cache_json="$cache_dir/cache.json"

    [ ! -f "$cache_json" ] && return 1

    local cached_version cached_filename
    cached_version=$(jq -r '.version // empty' "$cache_json" 2>/dev/null)
    cached_filename=$(jq -r '.filename // empty' "$cache_json" 2>/dev/null)

    [ -z "$cached_version" ] || [ -z "$cached_filename" ] && return 1
    [ "$cached_version" != "$expected_version" ] && return 1

    local cached_file="$cache_dir/$cached_filename"
    [ ! -f "$cached_file" ] && return 1

    local target_filename
    target_filename=$(basename "$target_file")
    [ "$cached_filename" != "$target_filename" ] && return 1

    mkdir -p "$(dirname "$target_file")"
    cp "$cached_file" "$target_file"
    return 0
}

save_cli_to_cache() {
    local source="$1"
    local version="$2"
    local downloaded_file="$3"

    [ "$CACHE_CLI" != "on" ] && return 0

    local cache_dir="$HOME/Enhancify/cli_cache/$source"
    mkdir -p "$cache_dir"

    local cli_filename
    cli_filename=$(basename "$downloaded_file")

    for old_cli in "$cache_dir"/CLI-*.jar; do
        [ -f "$old_cli" ] && [ "$old_cli" != "$cache_dir/$cli_filename" ] && rm -f "$old_cli"
    done

    cp "$downloaded_file" "$cache_dir/$cli_filename"

    jq -n \
        --arg version "$version" \
        --arg filename "$cli_filename" \
        '{"version": $version, "filename": $filename}' \
        > "$cache_dir/cache.json"
}

downloadFileWget() {
    local url="$1"
    local output_file="$2"
    local expected_size="$3"
    local gauge_text="$4"

    (
        "${WGET[@]}" "$url" -O "$output_file" |& \
        stdbuf -o0 cut -b 63-65 | stdbuf -o0 grep '[0-9]' | \
        while read -r line; do
            echo "$line"
        done
    ) | "${DIALOG[@]}" --gauge "$gauge_text" -1 -1 0

    if [ "$expected_size" = "0" ]; then
        [ -f "$output_file" ] && [ -s "$output_file" ]
    else
        [ "$expected_size" = "$(stat -c %s "$output_file" 2>/dev/null)" ]
    fi
}

downloadBatchAria2c() {
    local -n _dl_urls=$1
    local -n _dl_dirs=$2
    local -n _dl_files=$3
    local -n _dl_sizes=$4
    local -n _dl_labels=$5

    local total=${#_dl_urls[@]}
    local progress_dir
    progress_dir=$(mktemp -d)
    local -a pids=()

    local total_size=0
    local has_unknown_size=false
    for i in "${!_dl_sizes[@]}"; do
        if [ "${_dl_sizes[$i]}" = "0" ]; then
            has_unknown_size=true
        else
            (( total_size += _dl_sizes[$i] ))
        fi
    done

    local total_display
    if [ "$has_unknown_size" = true ]; then
        total_display="$(numfmt --to=iec --format='%0.1f' "$total_size" 2>/dev/null || echo "$total_size") + unknown"
    else
        total_display=$(numfmt --to=iec --format='%0.1f' "$total_size" 2>/dev/null || echo "$total_size")
    fi

    for i in "${!_dl_urls[@]}"; do
        echo "0" > "$progress_dir/$i"
        mkdir -p "${_dl_dirs[$i]}"

        (
            aria2c --console-log-level=warn --summary-interval=1 --download-result=hide \
                   --no-conf \
                   --dir="${_dl_dirs[$i]}" \
                   --out="${_dl_files[$i]}" \
                   --split=8 \
                   --min-split-size=5M \
                   --max-connection-per-server=8 \
                   --file-allocation=none \
                   --disk-cache=50M \
                   --enable-http-pipelining=true \
                   --connect-timeout=5 \
                   --timeout=15 \
                   --retry-wait=1 \
                   --max-tries=3 \
                   --auto-file-renaming=false \
                   --allow-overwrite=true \
                   "${_dl_urls[$i]}" 2>&1 | \
                while IFS= read -r line; do
                    if [[ "$line" =~ ([0-9]{1,3})% ]]; then
                        echo "${BASH_REMATCH[1]}" > "$progress_dir/$i"
                    fi
                done
        ) &
        pids+=($!)
    done

    while true; do
        local any_alive=false
        local gauge_args=()
        local total_progress=0

        for i in "${!_dl_labels[@]}"; do
            local progress size_display
            progress=$(cat "$progress_dir/$i" 2>/dev/null || echo "0")

            if [ "${_dl_sizes[$i]}" = "0" ]; then
                size_display="unknown"
            else
                size_display=$(numfmt --to=iec --format='%0.1f' "${_dl_sizes[$i]}" 2>/dev/null || echo "?")
            fi

            if kill -0 "${pids[$i]}" 2>/dev/null; then
                any_alive=true
                if [ "$progress" -gt 0 ] 2>/dev/null; then
                    gauge_args+=("${_dl_labels[$i]} ($size_display)" "-${progress}")
                else
                    gauge_args+=("${_dl_labels[$i]} ($size_display)" "7")
                fi
                (( total_progress += progress ))
            else
                local full_path="${_dl_dirs[$i]}/${_dl_files[$i]}"
                if [ "${_dl_sizes[$i]}" = "0" ]; then
                    if [ -f "$full_path" ] && [ -s "$full_path" ]; then
                        gauge_args+=("${_dl_labels[$i]} ($size_display)" "3")
                        (( total_progress += 100 ))
                    else
                        gauge_args+=("${_dl_labels[$i]} ($size_display)" "1")
                    fi
                else
                    if [ "${_dl_sizes[$i]}" == "$(stat -c %s "$full_path" 2>/dev/null)" ]; then
                        gauge_args+=("${_dl_labels[$i]} ($size_display)" "3")
                        (( total_progress += 100 ))
                    else
                        gauge_args+=("${_dl_labels[$i]} ($size_display)" "1")
                    fi
                fi
            fi
        done

        local overall=0
        [ "$total" -gt 0 ] && overall=$(( total_progress / total ))

        "${DIALOG[@]}" --title '| Downloading Assets |' --mixedgauge \
            "\n\n\n Downloading $total file(s) simultaneously\n Total: $total_display | Accelerated: 8 parts each\n" \
            -1 -1 "$overall" \
            "${gauge_args[@]}"

        $any_alive || break
        sleep 1
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done
    rm -rf "$progress_dir"

    for i in "${!_dl_dirs[@]}"; do
        local full_path="${_dl_dirs[$i]}/${_dl_files[$i]}"
        if [ "${_dl_sizes[$i]}" = "0" ]; then
            if [ ! -f "$full_path" ] || [ ! -s "$full_path" ]; then
                notify msg "Oops! ${_dl_labels[$i]} incomplete.\n\nRetry or change your Network."
                return 1
            fi
        else
            if [ "${_dl_sizes[$i]}" != "$(stat -c %s "$full_path" 2>/dev/null)" ]; then
                notify msg "Oops! ${_dl_labels[$i]} incomplete.\n\nRetry or change your Network."
                return 1
            fi
        fi
    done

    tput civis
}

downloadSequentialWget() {
    local -n _urls=$1
    local -n _dirs=$2
    local -n _files=$3
    local -n _sizes=$4
    local -n _labels=$5

    for i in "${!_urls[@]}"; do
        local file_path="${_dirs[$i]}/${_files[$i]}"
        mkdir -p "${_dirs[$i]}"

        local CTR=3
        local expected_size="${_sizes[$i]}"

        while true; do
            if [ "$expected_size" = "0" ]; then
                [ -f "$file_path" ] && [ -s "$file_path" ] && break
            else
                [ "$expected_size" = "$(stat -c %s "$file_path" 2>/dev/null)" ] && break
            fi

            [ $CTR -eq 0 ] && \
                notify msg "Oops! Unable to download ${_labels[$i]} completely.\n\nRetry or change your Network." && \
                return 1
            (( CTR-- ))

            local gauge_text="File    : ${_labels[$i]}\n"
            if [ "$expected_size" = "0" ]; then
                gauge_text+="Size    : Unavailable\n"
            else
                gauge_text+="Size    : $(numfmt --to=iec --format="%0.1f" "$expected_size")\n"
            fi
            gauge_text+="\nDownloading..."

            downloadFileWget "${_urls[$i]}" "$file_path" "$expected_size" "$gauge_text"
            tput civis
        done
    done
}

collectPendingDownloads() {
    dl_urls=()
    dl_dirs=()
    dl_files=()
    dl_sizes=()
    dl_labels=()

    local patches_actual_size
    patches_actual_size=$(stat -c %s "$PATCHES_FILE" 2>/dev/null)

    if [ "$PATCHES_SIZE" = "0" ]; then
        if [ ! -f "$PATCHES_FILE" ] || [ ! -s "$PATCHES_FILE" ]; then
            dl_urls+=("$PATCHES_URL")
            dl_dirs+=("$(dirname "$PATCHES_FILE")")
            dl_files+=("$(basename "$PATCHES_FILE")")
            dl_sizes+=("$PATCHES_SIZE")
            dl_labels+=("Patches-$PATCHES_VERSION.$PATCHES_EXT")
        fi
    else
        if [ "$PATCHES_SIZE" != "$patches_actual_size" ]; then
            dl_urls+=("$PATCHES_URL")
            dl_dirs+=("$(dirname "$PATCHES_FILE")")
            dl_files+=("$(basename "$PATCHES_FILE")")
            dl_sizes+=("$PATCHES_SIZE")
            dl_labels+=("Patches-$PATCHES_VERSION.$PATCHES_EXT")
        fi
    fi

    for var in $(compgen -v | grep "^ASSET_URL_"); do
        local name_var="${var/URL/NAME}"
        local size_var="${var/URL/SIZE}"
        local asset_url="${!var}"
        local asset_name="${!name_var}"
        local asset_size="${!size_var}"

        [ -z "$asset_name" ] && continue

        local asset_file="assets/$SOURCE/$asset_name"
        local actual_size
        actual_size=$(stat -c %s "$asset_file" 2>/dev/null)

        if [ "$asset_size" = "0" ]; then
            if [ ! -f "$asset_file" ] || [ ! -s "$asset_file" ]; then
                dl_urls+=("$asset_url")
                dl_dirs+=("$(dirname "$asset_file")")
                dl_files+=("$(basename "$asset_file")")
                dl_sizes+=("$asset_size")
                dl_labels+=("$asset_name")
            fi
        else
            if [ "$asset_size" != "$actual_size" ]; then
                dl_urls+=("$asset_url")
                dl_dirs+=("$(dirname "$asset_file")")
                dl_files+=("$(basename "$asset_file")")
                dl_sizes+=("$asset_size")
                dl_labels+=("$asset_name")
            fi
        fi
    done

    local cli_actual_size
    cli_actual_size=$(stat -c %s "$CLI_FILE" 2>/dev/null)

    local cli_ok=false
    if [ "$CLI_SIZE" = "0" ]; then
        [ -f "$CLI_FILE" ] && [ -s "$CLI_FILE" ] && cli_ok=true
    else
        [ "$CLI_SIZE" = "$cli_actual_size" ] && cli_ok=true
    fi

    if [ "$cli_ok" = false ]; then
        if get_cached_cli "$SOURCE" "$CLI_VERSION" "$CLI_FILE"; then
            notify info "CLI cache hit: CLI-$CLI_VERSION.jar"
        else
            dl_urls+=("$CLI_URL")
            dl_dirs+=("$(dirname "$CLI_FILE")")
            dl_files+=("$(basename "$CLI_FILE")")
            dl_sizes+=("$CLI_SIZE")
            dl_labels+=("CLI-$CLI_VERSION.jar")
        fi
    fi
}

get_patches_extension_from_api() {
    local api_response_file="$1"

    local response_data
    response_data=$(jq 'if type == "array" then .[0] else . end' "$api_response_file" 2>/dev/null)

    if jq -e '.assets[]? | select(.name | endswith(".mpp")) | select(.name | endswith(".asc") | not)' \
            <<< "$response_data" &>/dev/null; then
        echo "mpp"
        return 0
    fi

    if jq -e '.assets[]? | select(.name | endswith(".rvp")) | select(.name | endswith(".asc") | not)' \
            <<< "$response_data" &>/dev/null; then
        echo "rvp"
        return 0
    fi

    echo "mpp"
}

get_patches_extension() {
    local source="$1"

    if [ -d "assets/$source" ]; then
        if ls assets/"$source"/Patches-*.mpp 2>/dev/null | grep -q .; then
            echo "mpp"
            return 0
        fi
        if ls assets/"$source"/Patches-*.rvp 2>/dev/null | grep -q .; then
            echo "rvp"
            return 0
        fi
    fi

    echo "mpp"
}

update_source_json_branch() {
    local source_name="$1"
    local main_branch="$2"
    local dev_branch="$3"

    if [ "$USE_PRE_RELEASE" == "on" ]; then
        jq --arg source "$source_name" --arg main "$main_branch" --arg dev "$dev_branch" '
            (.[] | select(.source == $source) | .api.json) |= sub($main; $dev)
        ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
    else
        jq --arg source "$source_name" --arg main "$main_branch" --arg dev "$dev_branch" '
            (.[] | select(.source == $source) | .api.json) |= sub($dev; $main)
        ' sources.json > sources_tmp.json && mv sources_tmp.json sources.json
    fi
}

update_sources_json() {
    local sources_config=(
        "Anddea:main:dev"
        "De-ReVanced:main:dev"
        "ReVancedExperiments:main:dev"
        "PikoTwitter:main:dev"
        "MorpheApp:main:dev"
        "Wchill-patcheddit:main:dev"
        "RVX-Morphed:main:dev"
        "hoo-dles:main:dev"
        "AmpleRevanced:main:dev"
    )

    for config in "${sources_config[@]}"; do
        IFS=':' read -r source main_branch dev_branch <<< "$config"
        update_source_json_branch "$source" "$main_branch" "$dev_branch"
    done
}

showChangelog() {
    local changelog_tmp="$HOME/Enhancify/changelog.tmp"
    local changelog_display="$HOME/Enhancify/changelog_display.tmp"

    [ ! -f "$changelog_tmp" ] && return 0
    [ ! -s "$changelog_tmp" ] && rm -f "$changelog_tmp" && return 0

    local term_cols
    if command -v tput &>/dev/null; then
        term_cols=$(tput cols 2>/dev/null)
    fi
    if [ -z "$term_cols" ] || [ "$term_cols" -eq 0 ] 2>/dev/null; then
        if [ -n "$COLUMNS" ]; then
            term_cols="$COLUMNS"
        else
            term_cols=$(stty size 2>/dev/null | awk '{print $2}')
        fi
    fi
    [ -z "$term_cols" ] || [ "$term_cols" -eq 0 ] 2>/dev/null && term_cols=70

    local wrap_width=$(( term_cols - 8 ))
    [ "$wrap_width" -lt 25 ] && wrap_width=25

    local patches_size_display=""
    if [ -n "$PATCHES_SIZE" ] && [ "$PATCHES_SIZE" != "0" ] 2>/dev/null; then
        patches_size_display=$(numfmt --to=iec --format='%0.1f' "$PATCHES_SIZE")
    elif [ "$PATCHES_SIZE" = "0" ]; then
        patches_size_display="Unavailable"
    fi

    {
        echo " SOURCE  : $SOURCE"
        echo " Patches : ${PATCHES_VERSION}.${PATCHES_EXT}"
        if [ -n "$patches_size_display" ]; then
            echo " Size    : ${patches_size_display}"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    } > "$changelog_display"

    sed -E '
        s/\r//g
        /^\*\*Full Changelog\*\*/d
        /^Full Changelog/d
        /^##? ?\[?[0-9]+\.[0-9]+/d
        s/\[([^]]*)\]\([^)]*\)/\1/g
        s/\*\*([^*]*)\*\*/\1/g
        s/\*([^*]+)\*/\1/g
        s/`([^`]*)`/\1/g
        s/\([a-f0-9]{7,}\)//g
        s/\(#[0-9]+\)//g
        s/\(\s*\)//g
        s|https?://[^ ]*||g
        s/@[a-zA-Z0-9_.-]+//g
        s/<[^>]*>//g
        s/^\* /  • /
        s/^- /  • /
        s/[[:space:]]+$//
    ' "$changelog_tmp" | \
    awk '
        /^### / {
            sub(/^### /, "")
            print ""
            print "━━ " $0 " ━━"
            print ""
            next
        }
        { print }
    ' | \
    cat -s | \
    awk -v width="$wrap_width" '
    {
        line = $0

        if (line == "") { print ""; next }

        if (line ~ /^━━/) { print line; next }

        if (line ~ /^  • /) {
            prefix = "  • "
            indent = "    "
            text = substr(line, 5)
        } else {
            prefix = ""
            indent = ""
            text = line
        }

        max_first = width - length(prefix)
        if (max_first < 10) max_first = 10
        max_cont = width - length(indent)
        if (max_cont < 10) max_cont = 10

        remaining = text
        first = 1

        while (length(remaining) > 0) {
            if (first) { max = max_first } else { max = max_cont }

            if (length(remaining) <= max) {
                if (first) { print prefix remaining } else { print indent remaining }
                break
            }

            cut = 0
            for (i = max; i > 0; i--) {
                if (substr(remaining, i, 1) == " ") { cut = i; break }
            }
            if (cut == 0) cut = max

            chunk = substr(remaining, 1, cut)
            remaining = substr(remaining, cut + 1)
            sub(/^ /, "", remaining)

            if (first) { print prefix chunk; first = 0 }
            else        { print indent chunk }
        }
    }
    ' >> "$changelog_display"

    "${DIALOG[@]}" \
        --title '| Changelog |' \
        --exit-label "Download" \
        --scrollbar \
        --textbox "$changelog_display" -1 -1

    rm -f "$changelog_tmp" "$changelog_display"
}

fetch_revanced_custom_api() {
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
        -H "Accept: application/json")

    [ -n "$AUTH_HEADER" ] && CURL_CMD+=(-H "$AUTH_HEADER")

    local custom_api_url
    if [ "$USE_PRE_RELEASE" == "on" ]; then
        custom_api_url="https://api.revanced.app/v5/patches/prerelease"
    else
        custom_api_url="https://api.revanced.app/v5/patches"
    fi

    "${CURL_CMD[@]}" "$custom_api_url" > response.tmp 2>/dev/null

    if ! jq -e '.version' response.tmp &>/dev/null; then
        rm -f response.tmp
        return 1
    fi

    local version download_url description
    version=$(jq -r '.version // ""' response.tmp)
    download_url=$(jq -r '.download_url // ""' response.tmp)
    description=$(jq -r '.description // ""' response.tmp)

    if [ -z "$version" ] || [ -z "$download_url" ]; then
        rm -f response.tmp
        return 1
    fi

    version="${version#v}"

    local patches_ext="rvp"
    [[ "$download_url" == *.mpp ]] && patches_ext="mpp"

    {
        echo "PATCHES_VERSION='$version'"
        echo "PATCHES_EXT='$patches_ext'"
        echo "PATCHES_URL='$download_url'"
        echo "PATCHES_SIZE='0'"
    } > "assets/$SOURCE/.data"

    if [ -n "$description" ]; then
        mkdir -p "$HOME/Enhancify"
        echo "$description" > "$HOME/Enhancify/changelog.tmp"
    fi

    rm -f response.tmp
    return 0
}

resolve_cli_repo() {
    local patches_ext="$1"
    local source="$2"

    case "$source" in
        ReVanced)
            echo "ReVanced/revanced-cli"
            ;;
        *)
            if [ "$patches_ext" = "mpp" ]; then
                echo "MorpheApp/morphe-cli"
            else
                echo "inotia00/revanced-cli"
            fi
            ;;
    esac
}

fetch_cli_from_github() {
    local cli_repo="$1"

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

    [ -n "$AUTH_HEADER" ] && CURL_CMD+=(-H "$AUTH_HEADER" -D headers.tmp)

    local CLI_API_URL
    if [ "$USE_PRE_RELEASE" == "on" ]; then
        CLI_API_URL="https://api.github.com/repos/$cli_repo/releases"
    else
        CLI_API_URL="https://api.github.com/repos/$cli_repo/releases/latest"
    fi

    "${CURL_CMD[@]}" "$CLI_API_URL" > response.tmp 2>/dev/null

    if [ -n "$AUTH_HEADER" ] && [ -f headers.tmp ]; then
        response_headers=$(<headers.tmp)
        log_github_api_request "$CLI_API_URL" "$response_headers"
        rm -f headers.tmp
    fi

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
        rm -f response.tmp
        return 1
    fi

    rm -f response.tmp
    return 0
}

fetchAssetsInfo() {
    rm -f "$HOME/Enhancify/github_api_log.json"
    rm -f "$HOME/Enhancify/changelog.tmp"
    rm -f "$HOME/Enhancify/changelog_display.tmp"
    unset CLI_VERSION CLI_URL CLI_SIZE PATCHES_VERSION PATCHES_URL PATCHES_SIZE JSON_URL PATCHES_EXT

    for var in $(compgen -v | grep "^ASSET_"); do
        unset "$var"
    done

    local GITHUB_TOKEN
    GITHUB_TOKEN=$(read_github_token)
    local AUTH_HEADER="" AUTH_TEXT=""

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

    [ -n "$AUTH_HEADER" ] && CURL_CMD+=(-H "$AUTH_HEADER")
    CURL_CMD+=(-D headers.tmp)

    internet || return 1

    if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
        notify info "Initiating Network Acceleration ...\nFetching Assets Info... $AUTH_TEXT"
    else
        notify info "Fetching Assets Info... $AUTH_TEXT"
    fi

    "${CURL_CMD[@]}" "https://api.github.com/rate_limit" > response.tmp
    local response_headers
    response_headers=$(<headers.tmp)
    log_github_api_request "https://api.github.com/rate_limit" "$response_headers"
    local remaining
    remaining=$(jq -r '.resources.core.remaining' response.tmp)
    rm -f headers.tmp response.tmp

    if [ "$remaining" -le 3 ]; then
        notify msg "Unable to check for update.\nYou are probably rate-limited at this moment.\nTry again later or Run again with '-o' argument."
        return 1
    fi

    mkdir -p "assets/$SOURCE"
    rm -f "assets/$SOURCE/.data" "assets/.data"

    update_sources_json

    local REPO JSON_URL VERSION_URL
    source <(get_all_sources | jq -r --arg SOURCE "$SOURCE" '
        .[] | select(.source == $SOURCE) |
        "REPO=\(.repository)",
        (
            .api // empty |
            (
                (.json  // empty | "JSON_URL=\(.)"),
                (.version // empty | "VERSION_URL=\(.)")
            )
        )
    ')

    local PATCHES_API_URL use_custom_api=false

    if [ -n "$VERSION_URL" ]; then
        "${CURL_CMD[@]}" "$VERSION_URL" > response.tmp
        response_headers=$(<headers.tmp)
        log_github_api_request "$VERSION_URL" "$response_headers"
        rm -f headers.tmp

        local VERSION
        if VERSION=$(jq -r '.version' response.tmp 2>/dev/null) && [ -n "$VERSION" ]; then
            PATCHES_API_URL="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
        else
            rm -f response.tmp
            if [ "$SOURCE" == "ReVanced" ]; then
                notify info "GitHub API Fetching Failed\nRetrying with ReVanced custom API"
                use_custom_api=true
            else
                notify msg "Unable to fetch latest version from API!!\nRetry later."
                return 1
            fi
        fi
        rm -f response.tmp
    else
        if [ "$USE_PRE_RELEASE" == "on" ]; then
            PATCHES_API_URL="https://api.github.com/repos/$REPO/releases"
        else
            PATCHES_API_URL="https://api.github.com/repos/$REPO/releases/latest"
        fi
    fi

    if [ "$use_custom_api" == false ]; then
        "${CURL_CMD[@]}" "$PATCHES_API_URL" > response.tmp
        response_headers=$(<headers.tmp)
        log_github_api_request "$PATCHES_API_URL" "$response_headers"
        rm -f headers.tmp

        if ! jq -e 'if type == "array" then .[0] else . end | .tag_name' response.tmp &>/dev/null; then
            rm -f response.tmp
            if [ "$SOURCE" == "ReVanced" ]; then
                notify info "GitHub API Fetching Failed\nRetrying with ReVanced custom API"
                use_custom_api=true
            else
                notify msg "Unable to fetch latest Patches info from API!!\nRetry later."
                return 1
            fi
        else
            mkdir -p "$HOME/Enhancify"
            jq -r 'if type == "array" then .[0] else . end | .body // empty' \
                response.tmp > "$HOME/Enhancify/changelog.tmp" 2>/dev/null

            local PATCHES_EXT
            PATCHES_EXT=$(get_patches_extension_from_api "response.tmp")

            if ! jq -r --arg ext "$PATCHES_EXT" '
                    if type == "array" then .[0] else . end |
                "PATCHES_VERSION='\''\(.tag_name)'\''",
                "PATCHES_EXT='\''" + $ext + "'\''",
                (
                    .assets[] |
                    select(
                        (.name | endswith(".asc")  | not) and
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
                rm -f response.tmp
                if [ "$SOURCE" == "ReVanced" ]; then
                    notify info "GitHub API Fetching Failed\nRetrying with ReVanced custom API"
                    use_custom_api=true
                else
                    notify msg "Unable to fetch latest Patches info from API!!\nRetry later."
                    return 1
                fi
            fi
            rm -f response.tmp
        fi
    fi

    if [ "$use_custom_api" == true ]; then
        if ! fetch_revanced_custom_api; then
            notify msg "Failed to fetch patches from both GitHub and ReVanced API!!\nRetry later."
            return 1
        fi
    fi

    [ -n "$JSON_URL" ] && setEnv JSON_URL "$JSON_URL" init "assets/$SOURCE/.data"

    source "assets/$SOURCE/.data"

    local cli_repo
    cli_repo=$(resolve_cli_repo "$PATCHES_EXT" "$SOURCE")

    if ! fetch_cli_from_github "$cli_repo"; then
        notify msg "Unable to fetch latest CLI info from API!!\nRetry later."
        return 1
    fi

    source "assets/.data"
    source "assets/$SOURCE/.data"
}

fetchAssets() {

    if [ "$ASSETS_FETCHED" = "true" ] && [ "$ASSETS_FETCHED_SOURCE" = "$SOURCE" ]; then
        return 0
    fi

    fetchAssetsInfo || return 1

    source "assets/.data"
    source "assets/$SOURCE/.data"

    if [ -z "$PATCHES_EXT" ]; then
        PATCHES_EXT=$(get_patches_extension "$SOURCE")
    fi

    PATCHES_FILE="assets/$SOURCE/Patches-$PATCHES_VERSION.$PATCHES_EXT"
    CLI_FILE="assets/CLI-$CLI_VERSION.jar"

    for f in assets/"$SOURCE"/Patches-*; do
        [ "$f" = "$PATCHES_FILE" ] && continue
        [ -f "$f" ] && rm -f "$f"
    done

    for f in assets/CLI-*.jar; do
        [ "$f" = "$CLI_FILE" ] && continue
        [ -f "$f" ] && rm -f "$f"
    done

    showChangelog

    local -a dl_urls dl_dirs dl_files dl_sizes dl_labels
    collectPendingDownloads

    if [ ${#dl_urls[@]} -gt 0 ]; then
        if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
            downloadBatchAria2c dl_urls dl_dirs dl_files dl_sizes dl_labels || return 1
        else
            downloadSequentialWget dl_urls dl_dirs dl_files dl_sizes dl_labels || return 1
        fi
    fi

    if [ "$CACHE_CLI" = "on" ]; then
        local cli_actual_size
        cli_actual_size=$(stat -c %s "$CLI_FILE" 2>/dev/null)
        local cli_size_ok=false
        if [ "$CLI_SIZE" = "0" ]; then
            [ -f "$CLI_FILE" ] && [ -s "$CLI_FILE" ] && cli_size_ok=true
        else
            [ "$CLI_SIZE" = "$cli_actual_size" ] && cli_size_ok=true
        fi
        [ "$cli_size_ok" = true ] && save_cli_to_cache "$SOURCE" "$CLI_VERSION" "$CLI_FILE"
    fi

    ASSETS_FETCHED=true
    parsePatchesJson || return 1
}

deleteAssets() {
    if "${DIALOG[@]}" \
            --title '| Delete Assets |' \
            --defaultno \
            --yesno "Please confirm to delete the assets.\nIt will delete the CLI and patches." -1 -1 \
    ; then
        unset CLI_VERSION CLI_URL CLI_SIZE PATCHES_VERSION PATCHES_URL PATCHES_SIZE JSON_URL PATCHES_EXT
        for var in $(compgen -v | grep "^ASSET_"); do
            unset "$var"
        done
        rm -rf assets &>/dev/null
        rm -rf patch  &>/dev/null
        rm -f "$CLI_DETECTION_FILE" &>/dev/null
        rm -f "$HOME/Enhancify/changelog.tmp" &>/dev/null
        rm -f "$HOME/Enhancify/changelog_display.tmp" &>/dev/null
        mkdir assets

        ASSETS_FETCHED=false
        unset ASSETS_FETCHED_SOURCE
    fi
}
