#!/data/data/com.termux/files/usr/bin/bash

CLI_DIR="$HOME/Enhancify/assets"

cli_arg_detector() {
    local jar=$(find "$CLI_DIR" -maxdepth 1 -name "*.jar" 2>/dev/null | head -1)
    
    SUPPORTS_UNSIGNED="false"
    SUPPORTS_RIP_LIB="false"
    
    [[ ! -f "$jar" ]] && return 1
    
    local output=$(java -jar "$jar" patch --help 2>&1 || java -jar "$jar" patch 2>&1)
    
    echo "$output" | grep -qi "\-\-unsigned" && SUPPORTS_UNSIGNED="true"
    
    echo "$output" | grep -qi "\-\-rip-lib" && SUPPORTS_RIP_LIB="true"
    
    export SUPPORTS_UNSIGNED
    export SUPPORTS_RIP_LIB
    
    return 0
}
