#!/data/data/com.termux/files/usr/bin/bash

CLI_DIR="$HOME/Enhancify/assets"
CLI_DETECTION_FILE="$HOME/Enhancify/cli_detection.json"

cli_arg_detector() {
    local jar
    jar=$(find "$CLI_DIR" -maxdepth 1 -name "*.jar" 2>/dev/null | head -1)
    
    local unsigned="false"
    local riplib="false"
    
    if [[ ! -f "$jar" ]]; then
        jq -n '{unsigned: false, riplib: false}' > "$CLI_DETECTION_FILE"
        export SUPPORTS_UNSIGNED="false"
        export SUPPORTS_RIP_LIB="false"
        return 1
    fi
    
    local output
    output=$(java -jar "$jar" patch --help 2>&1 || java -jar "$jar" patch 2>&1)
    
    echo "$output" | grep -qi "\-\-unsigned" && unsigned="true"
    echo "$output" | grep -qi "\-\-rip-lib" && riplib="true"
    
    jq -n \
        --argjson unsigned "$unsigned" \
        --argjson riplib "$riplib" \
        '{unsigned: $unsigned, riplib: $riplib}' > "$CLI_DETECTION_FILE"
    
    export SUPPORTS_UNSIGNED="$unsigned"
    export SUPPORTS_RIP_LIB="$riplib"
    
    return 0
}
