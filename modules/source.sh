#!/usr/bin/bash

get_source_from_config() {
    local config_file="$HOME/Enhancify/.config"
    if [ -f "$config_file" ]; then
        grep -oP "^SOURCE='\K[^']+" "$config_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

has_github_token() {
    local token_file="$HOME/Enhancify/github_token.json"
    
    if [ -f "$token_file" ]; then
        local token
        token=$(jq -r '.token' "$token_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            return 0
        fi
    fi
    return 1
}

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

fetch_latest_tag() {
    local repo="$1"
    local token="$2"
    
    local curl_args=(-s --compressed 
        -H "Accept: application/vnd.github+json" 
        -H "X-GitHub-Api-Version: 2022-11-28"
        -A "$USER_AGENT_GITHUB")
    
    [ -n "$token" ] && curl_args+=(-H "Authorization: Bearer $token")
    
    local response
    response=$(curl "${curl_args[@]}" "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)
    
    if echo "$response" | jq -e '.tag_name' &>/dev/null; then
        echo "$response" | jq -r '.tag_name'
    else
        echo ""
    fi
}

fetch_prerelease_tag() {
    local repo="$1"
    local token="$2"
    
    local curl_args=(-s --compressed 
        -H "Accept: application/vnd.github+json" 
        -H "X-GitHub-Api-Version: 2022-11-28"
        -A "$USER_AGENT_GITHUB")
    
    [ -n "$token" ] && curl_args+=(-H "Authorization: Bearer $token")
    
    local response
    response=$(curl "${curl_args[@]}" "https://api.github.com/repos/$repo/releases?per_page=1" 2>/dev/null)
    
    if echo "$response" | jq -e '.[0].tag_name' &>/dev/null; then
        echo "$response" | jq -r '.[0].tag_name'
    else
        echo ""
    fi
}

init_tags_file() {
    local tags_file="$HOME/Enhancify/tag.json"
    mkdir -p "$HOME/Enhancify"
    
    if [ ! -f "$tags_file" ]; then
        jq -n --arg ts "$(date +%s)" '{
            _meta: {
                timestamp: ($ts | tonumber),
                has_token: "false"
            },
            sources: {}
        }' > "$tags_file"
    fi
}

should_refresh_tags() {
    local tags_file="$HOME/Enhancify/tag.json"
    
    [ ! -f "$tags_file" ] && return 0
    
    local stored_has_token
    stored_has_token=$(jq -r '._meta.has_token // "false"' "$tags_file" 2>/dev/null)
    local current_has_token="false"
    has_github_token && current_has_token="true"
    
    [ "$stored_has_token" != "$current_has_token" ] && return 0
    
    local stored_timestamp current_time age
    stored_timestamp=$(jq -r '._meta.timestamp // 0' "$tags_file" 2>/dev/null)
    current_time=$(date +%s)
    age=$((current_time - stored_timestamp))
    
    [ $age -gt 1800 ] && return 0
    
    return 1
}

has_source_tags() {
    local source="$1"
    local tags_file="$HOME/Enhancify/tag.json"
    
    [ ! -f "$tags_file" ] && return 1
    
    jq -e --arg s "$source" '.sources[$s] // empty' "$tags_file" &>/dev/null
}

is_custom_source() {
    local source="$1"
    init_user_sources
    jq -e --arg s "$source" '.[] | select(.source == $s)' user_sources.json &>/dev/null
}

get_source_repo() {
    local source="$1"
    get_all_sources | jq -r --arg s "$source" '.[] | select(.source == $s) | .repository // ""'
}

save_source_tags() {
    local tags_file="$HOME/Enhancify/tag.json"
    local source="$1"
    local latest="$2"
    local prerelease="$3"
    
    local is_custom="false"
    is_custom_source "$source" && is_custom="true"
    
    jq --arg src "$source" \
       --arg lat "$latest" \
       --arg pre "$prerelease" \
       --arg cus "$is_custom" \
       '.sources[$src] = {
           latest: $lat,
           prerelease: $pre,
           custom: ($cus == "true")
       }' "$tags_file" > tmp_tag.json && mv tmp_tag.json "$tags_file"
}

update_tags_json() {
    local tags_file="$HOME/Enhancify/tag.json"
    local token=""
    local has_token="false"
    
    init_tags_file
    
    token=$(read_github_token)
    [ -n "$token" ] && has_token="true"
    
    local current_source
    current_source=$(get_source_from_config)
    [ -z "$current_source" ] && current_source="$SOURCE"
    
    jq --arg ts "$(date +%s)" --arg ht "$has_token" \
        '._meta.timestamp = ($ts | tonumber) | ._meta.has_token = $ht' \
        "$tags_file" > tmp_tag.json && mv tmp_tag.json "$tags_file"
    
    local sources_to_process=()
    
    if [ "$has_token" = "true" ]; then
        readarray -t sources_to_process < <(get_all_sources | jq -r '.[].source')
        notify info "Fetching tags for ${#sources_to_process[@]} sources... [Authenticated]"
    else
        [ -n "$current_source" ] && sources_to_process=("$current_source")
        notify info "Fetching tags for $current_source..."
    fi
    
    local total=${#sources_to_process[@]}
    local count=0
    
    (
        for source in "${sources_to_process[@]}"; do
            ((count++))
            
            local repo
            repo=$(get_source_repo "$source")
            
            if [ -n "$repo" ] && [ "$repo" != "null" ]; then
                local latest_tag prerelease_tag
                
                latest_tag=$(fetch_latest_tag "$repo" "$token")
                
                prerelease_tag=$(fetch_prerelease_tag "$repo" "$token")
                
                save_source_tags "$source" "$latest_tag" "$prerelease_tag"
            fi
            
            [ $total -gt 1 ] && echo $((count * 100 / total))
        done
    ) | if [ $total -gt 1 ]; then
        "${DIALOG[@]}" --gauge "Fetching release tags..." -1 -1
    else
        cat > /dev/null
    fi
}

get_source_tag_display() {
    local source="$1"
    local tags_file="$HOME/Enhancify/tag.json"
    
    [ ! -f "$tags_file" ] && echo "" && return
    
    local latest prerelease
    latest=$(jq -r --arg s "$source" '.sources[$s].latest // ""' "$tags_file" 2>/dev/null)
    prerelease=$(jq -r --arg s "$source" '.sources[$s].prerelease // ""' "$tags_file" 2>/dev/null)
    
    if [ "$USE_PRE_RELEASE" == "on" ]; then
        [ -n "$prerelease" ] && echo "$prerelease" || echo "$latest"
    else
        [ -n "$latest" ] && echo "$latest" || echo "$prerelease"
    fi
}

refresh_tags() {
    rm -f "$HOME/Enhancify/tag.json"
    update_tags_json
}

changeSource() {
    init_user_sources
    local tags_file="$HOME/Enhancify/tag.json"
    local has_token=false
    
    has_github_token && has_token=true
    
    local current_source
    current_source=$(get_source_from_config)
    [ -z "$current_source" ] && current_source="$SOURCE"
    
    if should_refresh_tags; then
        update_tags_json
    elif [ "$has_token" = false ] && ! has_source_tags "$current_source"; then
        update_tags_json
    fi
    
    local SELECTED_SOURCE
    local SOURCES_ITEMS=()
    
    while IFS= read -r source_name; do
        local tag_display=""
        local source_marker=""
        
        is_custom_source "$source_name" && source_marker="*"
        
        if [ "$has_token" = true ]; then
            tag_display=$(get_source_tag_display "$source_name")
        else
            [ "$source_name" == "$current_source" ] && tag_display=$(get_source_tag_display "$source_name")
        fi
        
        [ -n "$tag_display" ] && tag_display="[$tag_display]$source_marker" || tag_display="[-]$source_marker"
        
        local status="off"
        [ "$source_name" == "$SOURCE" ] && status="on"
        
        SOURCES_ITEMS+=("$source_name" "$tag_display" "$status")
    done < <(get_all_sources | jq -r '.[].source')
    
    local builtin_count custom_count
    builtin_count=$(jq 'length' sources.json)
    custom_count=$(jq 'length' user_sources.json 2>/dev/null || echo 0)
    
    local last_update=""
    if [ -f "$tags_file" ]; then
        local timestamp
        timestamp=$(jq -r '._meta.timestamp // 0' "$tags_file" 2>/dev/null)
        if [ "$timestamp" != "0" ] && [ -n "$timestamp" ]; then
            last_update=$(date -d "@$timestamp" "+%Y-%m-%d" 2>/dev/null || date -r "$timestamp" "+%Y-%m-%d" 2>/dev/null)
        fi
    fi
    
    local hint_text="$NAVIGATION_HINT\n$SELECTION_HINT"
    hint_text+="\nSources: $builtin_count built-in | $custom_count custom (* = custom)"
    
    local status_line=""
    if [ "$has_token" = true ]; then
        status_line="[Token Authenticated]"
    else
        status_line="[Token Unauthenticated]"
    fi
    
    if [ -n "$last_update" ]; then
        status_line+=" | Updated: $last_update"
    fi
    
    if [ "$USE_PRE_RELEASE" == "on" ]; then
        status_line+=" | [Pre-release]"
    else
        status_line+=" | [Stable]"
    fi
    
    hint_text+="\n$status_line"

    tput civis 2>/dev/null
    
    SELECTED_SOURCE=$(
        "${DIALOG[@]}" \
            --title '| Source Selection Menu |' \
            --no-cancel \
            --ok-label 'Done' \
            --extra-button \
            --extra-label 'Refresh' \
            --radiolist "$hint_text" -1 -1 0 \
            "${SOURCES_ITEMS[@]}" 2>&1 > /dev/tty
    )
    
    local exit_code=$?
    
    [ $exit_code -eq 3 ] && refresh_tags && changeSource && return
    
    [ -z "$SELECTED_SOURCE" ] && return
    [ "$SOURCE" == "$SELECTED_SOURCE" ] && return
    
    SOURCE="$SELECTED_SOURCE"
    setEnv SOURCE "$SOURCE" update .config
    
    rm -rf assets &> /dev/null
    rm -rf patch &> /dev/null
    rm -f "$CLI_DETECTION_FILE" &> /dev/null
    mkdir assets
    
    [ "$has_token" = false ] && rm -f "$tags_file"
    
    unset AVAILABLE_PATCHES APPS_INFO APPS_LIST ENABLED_PATCHES
}
