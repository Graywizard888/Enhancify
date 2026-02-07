#!/usr/bin/bash

MIN_HEAP=1024
CUSTOM_KEYSTORE_DIR="$HOME/Enhancify/keystore"
CLI_DETECTION_FILE="$HOME/Enhancify/cli_detection.json"
SUPPORTED_EXTENSIONS=("apk" "apkm" "xapk" "apks")

USE_PARALLEL_GC="${USE_PARALLEL_GC:-off}"

getJavaVersion() {
    local VERSION
    VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
    VERSION="${VERSION//[!0-9]/}"
    [ -z "$VERSION" ] && VERSION=0
    echo "$VERSION"
}

checkJavaVersion() {
    local JAVA_VER
    JAVA_VER=$(getJavaVersion)
    if [ "$JAVA_VER" -eq 17 ] || [ "$JAVA_VER" -eq 21 ]; then
        return 0
    else
        return 1
    fi
}

getJavaFullVersion() {
    java -version 2>&1 | head -n 1
}

getAvailableMemory() {
    local MEM
    MEM=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
    if [ -z "$MEM" ] || [ "$MEM" -eq 0 ]; then
        MEM=$(free -m 2>/dev/null | awk '/^Mem:/{print $4}')
    fi
    [ -z "$MEM" ] && MEM=1024
    echo "$MEM"
}

getTotalMemory() {
    free -m 2>/dev/null | awk '/^Mem:/{print $2}'
}

calculateHeapSize() {
    local AVAILABLE_MEM HEAP_SIZE MAX_HEAP
    AVAILABLE_MEM=$(getAvailableMemory)
    MAX_HEAP=$((AVAILABLE_MEM * 75 / 100))
    HEAP_SIZE=$MAX_HEAP
    [ "$HEAP_SIZE" -lt "$MIN_HEAP" ] && HEAP_SIZE=$MIN_HEAP
    echo "$HEAP_SIZE"
}

getMaxHeap() {
    local AVAILABLE_MEM MAX_HEAP
    AVAILABLE_MEM=$(getAvailableMemory)
    MAX_HEAP=$((AVAILABLE_MEM * 75 / 100))
    [ "$MAX_HEAP" -lt "$MIN_HEAP" ] && MAX_HEAP=$MIN_HEAP
    echo "$MAX_HEAP"
}

checkMemory() {
    AVAILABLE_MEM=$(getAvailableMemory)
    if [ "$AVAILABLE_MEM" -lt "$MIN_HEAP" ]; then
        "${DIALOG[@]}" \
            --title '| Low Memory Warning |' \
            --yesno "\nLow memory detected!\n\n  Available : ${AVAILABLE_MEM}MB\n  Required  : ${MIN_HEAP}MB\n\nPatching may fail due to insufficient memory.\n\nRecommendations:\n • Close background apps\n • Restart Termux\n • Free up RAM\n\nDo you still want to continue anyway?" 18 50
        case "$?" in
            0) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

checkParallelGCConditions() {
    local JAVA_VER AVAILABLE_MEM
    
    if [ "$USE_PARALLEL_GC" != "on" ]; then
        return 1
    fi
    
    JAVA_VER=$(getJavaVersion)
    if [ "$JAVA_VER" -ne 17 ] && [ "$JAVA_VER" -ne 21 ]; then
        return 2
    fi
    
    AVAILABLE_MEM=$(getAvailableMemory)
    if [ "$AVAILABLE_MEM" -lt "$MIN_HEAP" ]; then
        return 3
    fi
    
    return 0
}

getParallelGCFailReason() {
    local JAVA_VER AVAILABLE_MEM
    JAVA_VER=$(getJavaVersion)
    AVAILABLE_MEM=$(getAvailableMemory)
    
    if [ "$JAVA_VER" -ne 17 ] && [ "$JAVA_VER" -ne 21 ]; then
        echo "Java $JAVA_VER detected (requires 17 or 21)"
    elif [ "$AVAILABLE_MEM" -lt "$MIN_HEAP" ]; then
        echo "Low memory: ${AVAILABLE_MEM}MB (requires ${MIN_HEAP}MB)"
    else
        echo "Unknown condition failed"
    fi
}

buildParallelGCArgs() {
    local HEAP_SIZE="$1"
    local JAVA_VER CPU_CORES PARALLEL_THREADS INITIAL_HEAP
    
    JAVA_VER=$(getJavaVersion)
    CPU_CORES=$(nproc 2>/dev/null || echo 4)
    PARALLEL_THREADS=$CPU_CORES
    INITIAL_HEAP=$((HEAP_SIZE / 3))
    
    JAVA_ARGS=(
        "-Djava.awt.headless=true"
        "-Dfile.encoding=UTF-8"
        "-Djava.io.tmpdir=$TMPDIR"
        "-Xmx${HEAP_SIZE}m"
        "-Xms${INITIAL_HEAP}m"
        "-Xss500k"
        "-XX:+UseParallelGC"
        "-XX:ParallelGCThreads=$PARALLEL_THREADS"
        "-XX:GCTimeRatio=15"
        "-XX:NewRatio=2"
        "-XX:SurvivorRatio=6"
        "-XX:MaxTenuringThreshold=6"
        "-XX:TargetSurvivorRatio=90"
        "-XX:+UseAdaptiveSizePolicy"
        "-XX:AdaptiveSizePolicyWeight=90"
        "-XX:YoungGenerationSizeIncrement=20"
        "-XX:AdaptiveSizeDecrementScaleFactor=2"
        "-XX:MetaspaceSize=96m"
        "-XX:MaxMetaspaceSize=192m"
        "-XX:ReservedCodeCacheSize=128m"
        "-XX:InitialCodeCacheSize=32m"
        "-XX:+UseCompressedOops"
        "-XX:+UseCompressedClassPointers"
        "-XX:+UseTLAB"
        "-XX:TLABSize=96k"
        "-XX:MinHeapFreeRatio=20"
        "-XX:MaxHeapFreeRatio=40"
        "-XX:SoftRefLRUPolicyMSPerMB=50"
        "-XX:+UseGCOverheadLimit"
        "-XX:GCTimeLimit=90"
        "-XX:GCHeapFreeLimit=10"
        "-XX:+ParallelRefProcEnabled"
        "-XX:+ScavengeBeforeFullGC"
        "-XX:+DisableExplicitGC"
        "-XX:+TieredCompilation"
        "-XX:CICompilerCount=3"
        "-XX:CompileThreshold=1000"
        "-XX:+OptimizeStringConcat"
        "-XX:MaxInlineSize=100"
        "-XX:FreqInlineSize=200"
        "-XX:-UsePerfData"
    )
    
    if [ "$JAVA_VER" -eq 17 ] || [ "$JAVA_VER" -eq 21 ]; then
        JAVA_ARGS+=(
            "--add-opens=java.base/java.lang=ALL-UNNAMED"
            "--add-opens=java.base/java.util=ALL-UNNAMED"
            "--add-opens=java.base/java.io=ALL-UNNAMED"
            "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED"
            "--add-opens=java.base/java.nio=ALL-UNNAMED"
        )
    fi
    
    printf '%s\n' "${JAVA_ARGS[@]}"
}

buildJavaArgs() {
    local HEAP_SIZE="$1"
    local JAVA_VER CPU_CORES
    JAVA_VER=$(getJavaVersion)
    CPU_CORES=$(nproc 2>/dev/null || echo 4)
    
    PARALLEL_GC_THREADS=$CPU_CORES
    CONC_GC_THREADS=$((CPU_CORES / 4))
    [ $CONC_GC_THREADS -lt 2 ] && CONC_GC_THREADS=2
    
    JAVA_ARGS=(
        "-Djava.awt.headless=true"
        "-Xmx${HEAP_SIZE}m"
        "-Xms$((HEAP_SIZE / 3))m"
        "-Djava.io.tmpdir=$TMPDIR"
        "-XX:-UsePerfData"
        "-Dfile.encoding=UTF-8"
    )
    
    if [ "$JAVA_VER" -eq 17 ] || [ "$JAVA_VER" -eq 21 ]; then
        JAVA_ARGS+=(
            "-XX:+UseG1GC"
            "-XX:MaxGCPauseMillis=150"
            "-XX:G1HeapRegionSize=2m"
            "-XX:+UseStringDeduplication"
            "-XX:+ParallelRefProcEnabled"
            "-XX:ConcGCThreads=$CONC_GC_THREADS"
            "-XX:ParallelGCThreads=$PARALLEL_GC_THREADS"
            "-XX:CICompilerCount=3"
            "-XX:+UseCompressedOops"
            "-XX:+UseCompressedClassPointers"
            "-XX:+OptimizeStringConcat"
            "-XX:+DisableExplicitGC"
            "-XX:+TieredCompilation"
            "-XX:ReservedCodeCacheSize=128m"
            "-XX:InitialCodeCacheSize=32m"
            "-XX:MaxMetaspaceSize=128m"
            "-XX:SoftRefLRUPolicyMSPerMB=50"
            "--add-opens=java.base/java.lang=ALL-UNNAMED"
            "--add-opens=java.base/java.util=ALL-UNNAMED"
            "--add-opens=java.base/java.io=ALL-UNNAMED"
        )
    fi
    
    printf '%s\n' "${JAVA_ARGS[@]}"
}

buildLightweightJavaArgs() {
    local HEAP_SIZE="$1"
    JAVA_ARGS=(
        "-Djava.awt.headless=true"
        "-Xmx${HEAP_SIZE}m"
        "-Xms128m"
        "-Dfile.encoding=UTF-8"
        "-Djava.io.tmpdir=$TMPDIR"
        "-XX:+UseSerialGC"
        "-XX:TieredStopAtLevel=1"
        "-XX:+UseCompressedOops"
        "-XX:-UsePerfData"
        "-XX:CICompilerCount=1"
        "-XX:ReservedCodeCacheSize=32m"
        "--add-opens=java.base/java.lang=ALL-UNNAMED"
        "--add-opens=java.base/java.util=ALL-UNNAMED"
        "--add-opens=java.base/java.io=ALL-UNNAMED"
    )
    printf '%s\n' "${JAVA_ARGS[@]}"
}

getApkExtension() {
    local APP_DIR="apps/$APP_NAME"
    for ext in "${SUPPORTED_EXTENSIONS[@]}"; do
        if [ -f "$APP_DIR/$APP_VER.$ext" ]; then
            echo "$ext"
            return 0
        fi
    done
    echo ""
    return 1
}

getInputApkPath() {
    local APP_DIR="apps/$APP_NAME"
    local EXT
    EXT=$(getApkExtension)
    if [ -n "$EXT" ]; then
        echo "$APP_DIR/$APP_VER.$EXT"
        return 0
    fi
    echo ""
    return 1
}

getOutputApkPath() {
    echo "apps/$APP_NAME/$APP_VER-$SOURCE.apk"
}

isSplitApk() {
    local EXT="$1"
    case "$EXT" in
        apkm|xapk|apks) return 0 ;;
        *) return 1 ;;
    esac
}

getApkFormatInfo() {
    local EXT="$1"
    case "$EXT" in
        apk) echo "Standard APK" ;;
        apkm) echo "Split APK (APKM)" ;;
        xapk) echo "Split APK (XAPK)" ;;
        apks) echo "Split APK (APKS)" ;;
        *) echo "Unknown" ;;
    esac
}

getDeviceArch() {
    local DEVICE_ARCH
    DEVICE_ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)
    case "$DEVICE_ARCH" in
        arm64-v8a|arm64*) echo "arm64-v8a" ;;
        armeabi-v7a|armeabi*|armv7*) echo "armeabi-v7a" ;;
        x86_64) echo "x86_64" ;;
        x86) echo "x86" ;;
        *) echo "arm64-v8a" ;;
    esac
}

getRipLibsArgs() {
    local DEVICE_ARCH="$1"
    local RIP_ARGS=()
    local ALL_ARCHS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
    for arch in "${ALL_ARCHS[@]}"; do
        if [ "$arch" != "$DEVICE_ARCH" ]; then
            RIP_ARGS+=("--rip-lib=$arch")
        fi
    done
    printf '%s\n' "${RIP_ARGS[@]}"
}

shouldUseCliOverride() {
    [ "$CLI_RIPLIB_ANTISPLIT" = "on" ]
}

hasCustomKeystore() {
    [ -d "$CUSTOM_KEYSTORE_DIR" ]
}

removeInternalKeystore() {
    if [ "$SOURCE" == "MorpheApp" ] || [ "$SOURCE" == "Wchill-patcheddit" ] || [ "$SOURCE" == "RVX-Morphed" ] || [ "$SOURCE" == "Anddea-Morphed" ]; then
        rm -f "$STORAGE/revancify.keystore" 2>/dev/null
    fi
}

loadCliCapabilities() {
    if [ -f "$CLI_DETECTION_FILE" ]; then
        SUPPORTS_UNSIGNED=$(jq -r '.unsigned // false' "$CLI_DETECTION_FILE" 2>/dev/null || echo "false")
        SUPPORTS_RIP_LIB=$(jq -r '.riplib // false' "$CLI_DETECTION_FILE" 2>/dev/null || echo "false")
        export SUPPORTS_UNSIGNED SUPPORTS_RIP_LIB
        return 0
    else
        cli_arg_detector >/dev/null 2>&1
        if [ -f "$CLI_DETECTION_FILE" ]; then
            SUPPORTS_UNSIGNED=$(jq -r '.unsigned // false' "$CLI_DETECTION_FILE" 2>/dev/null || echo "false")
            SUPPORTS_RIP_LIB=$(jq -r '.riplib // false' "$CLI_DETECTION_FILE" 2>/dev/null || echo "false")
            export SUPPORTS_UNSIGNED SUPPORTS_RIP_LIB
            return 0
        else
            SUPPORTS_UNSIGNED="false"
            SUPPORTS_RIP_LIB="false"
            export SUPPORTS_UNSIGNED SUPPORTS_RIP_LIB
            return 1
        fi
    fi
}

cleanupCliDetection() {
    rm -f "$CLI_DETECTION_FILE" 2>/dev/null
}

findPatchedApp() {
    local OUTPUT_PATH
    OUTPUT_PATH=$(getOutputApkPath)
    if [ -e "$OUTPUT_PATH" ]; then
        "${DIALOG[@]}" \
            --title '| Patched apk found |' \
            --defaultno \
            --yes-label 'Patch' \
            --no-label 'Install' \
            --help-button \
            --help-label 'Back' \
            --yesno "Current directory already contains Patched $APP_NAME version $APP_VER.\n\n\nDo you want to patch $APP_NAME again?" -1 -1
        case "$?" in
            0) rm "$OUTPUT_PATH" ;;
            1) TASK="INSTALL_APP"; return 1 ;;
            2) return 1 ;;
        esac
    else
        return 0
    fi
}

patchApp() {
    local INPUT_PATH INPUT_EXT OUTPUT_PATH FORMAT_INFO
    local PATCH_SUCCESS=0
    local GC_OVERRIDE_MSG=""
    
    INPUT_EXT=$(getApkExtension)
    if [ -z "$INPUT_EXT" ]; then
        notify msg "APK not found !!\nSupported formats: APK, APKM, XAPK, APKS\nTry importing from Storage."
        return 1
    fi
    
    INPUT_PATH=$(getInputApkPath)
    OUTPUT_PATH=$(getOutputApkPath)
    FORMAT_INFO=$(getApkFormatInfo "$INPUT_EXT")
    
    if [ ! -e "$INPUT_PATH" ]; then
        notify msg "APK not found !!\nTry importing APK from Storage."
        return 1
    fi

    removeInternalKeystore

    JAVA_VER=$(getJavaVersion)
    JAVA_FULL_VER=$(getJavaFullVersion)

    if ! checkJavaVersion; then
        "${DIALOG[@]}" \
            --title '| Java Version Warning |' \
            --yesno "\nUnsupported Java version detected!\n\nDetected: Java $JAVA_VER\nSupported: OpenJDK 17 or 21\n\nScript is optimized for OpenJDK 17/21.\nContinue with current Java?" 14 50
        case "$?" in
            0) ;;
            *) return 1 ;;
        esac
    fi

    if ! checkMemory; then
        notify msg "Patching cancelled due to low memory."
        return 1
    fi

    HEAP_SIZE=$(calculateHeapSize)
    MAX_HEAP=$(getMaxHeap)
    AVAILABLE_MEM=$(getAvailableMemory)
    TOTAL_MEM=$(getTotalMemory)
    CPU_CORES=$(nproc 2>/dev/null || echo 4)
    
    GC_MODE="g1"
    GC_INFO="G1GC (Default)"
    
    if [ "$USE_PARALLEL_GC" = "on" ]; then
        if checkParallelGCConditions; then
            readarray -t JAVA_ARGS < <(buildParallelGCArgs "$HEAP_SIZE")
            GC_MODE="Parallel Engine"
            GC_INFO="ParallelGC (Enabled)"
        else
            local FAIL_REASON
            FAIL_REASON=$(getParallelGCFailReason)
            notify msg "Parallel GC conditions not met\n$FAIL_REASON\n\nOverriding to G1GC"
            readarray -t JAVA_ARGS < <(buildJavaArgs "$HEAP_SIZE")
            GC_MODE="G1 Engine"
            GC_INFO="G1GC (Parallel GC Override - $FAIL_REASON)"
            GC_OVERRIDE_MSG="Parallel GC requested but conditions not met: $FAIL_REASON"
        fi
    else
        readarray -t JAVA_ARGS < <(buildJavaArgs "$HEAP_SIZE")
        GC_MODE="G1 Engine"
        GC_INFO="G1GC (Default)"
    fi
    
    local DEVICE_ARCH RIP_LIBS_ARGS=() RIP_LIBS_INFO="Disabled"
    DEVICE_ARCH=$(getDeviceArch)
    
    if shouldUseCliOverride; then
        loadCliCapabilities
        if [ "$SUPPORTS_RIP_LIB" = "true" ]; then
            readarray -t RIP_LIBS_ARGS < <(getRipLibsArgs "$DEVICE_ARCH")
            RIP_LIBS_INFO="CLI Override: Enabled (Keeping $DEVICE_ARCH)"
        else
            RIP_LIBS_ARGS=()
            RIP_LIBS_INFO="CLI Override: Not Supported by $SOURCE CLI"
        fi
    else
        RIP_LIBS_INFO="Optimize Libs: $DEVICE_ARCH"
    fi
    
    local SIGNING_ARGS=() SIGNING_INFO
    if shouldUseCliOverride && [ "$SUPPORTS_UNSIGNED" = "true" ] && hasCustomKeystore; then
        SIGNING_ARGS=("--unsigned")
        SIGNING_INFO="Unsigned (Custom keystore will be used)"
    else
        SIGNING_ARGS=("--keystore=$STORAGE/revancify.keystore")
        if shouldUseCliOverride && [ "$SUPPORTS_UNSIGNED" = "true" ] && ! hasCustomKeystore; then
            SIGNING_INFO="CLI keystore (No custom keystore found)"
        elif shouldUseCliOverride && [ "$SUPPORTS_UNSIGNED" != "true" ]; then
            SIGNING_INFO="CLI keystore (--unsigned not supported by $SOURCE)"
        elif ! shouldUseCliOverride; then
            SIGNING_INFO="CLI keystore (CLI override disabled)"
        else
            SIGNING_INFO="CLI keystore"
        fi
    fi
    
    readarray -t ARGUMENTS < <(
        jq -nrc --arg PKG_NAME "$PKG_NAME" --argjson ENABLED_PATCHES "$ENABLED_PATCHES" '
            $ENABLED_PATCHES[] |
            select(.pkgName == $PKG_NAME) |
            .options as $OPTIONS |
            .patches[] |
            . as $PATCH_NAME |
            "--enable",
            $PATCH_NAME,
            (
                $OPTIONS[] |
                if .patchName == $PATCH_NAME then
                    "--options=" +
                    .key + "=" +
                    (
                        .value |
                        if . != null then
                            . | tostring
                        else
                            empty
                        end
                    )
                else
                    empty
                end
            )
        '
    )

    cat > "$STORAGE/patch_log.txt" << EOF
╔═══════════════════════════════════════════════════════════════╗
║                     Enhancify PATCH LOG
╠═══════════════════════════════════════════════════════════════╣
║ Date: $(date)
╠═══════════════════════════════════════════════════════════════╣
║ SYSTEM INFO
╠═══════════════════════════════════════════════════════════════╣
║ Root Access       : $ROOT_ACCESS
║ Rish Access       : $RISH_ACCESS
║ Architecture      : $ARCH
║ Device Arch       : $DEVICE_ARCH
║ CPU Cores         : $CPU_CORES
╠═══════════════════════════════════════════════════════════════╣
║ JAVA INFO
╠═══════════════════════════════════════════════════════════════╣
║ Java Version      : $JAVA_FULL_VER
║ Major Version     : $JAVA_VER
║ GC Type           : $GC_INFO
║ GC Mode           : $GC_MODE
║$([ -n "$GC_OVERRIDE_MSG" ] && echo "║ GC Override       : $GC_OVERRIDE_MSG")
╠═══════════════════════════════════════════════════════════════╣
║ MEMORY INFO
╠═══════════════════════════════════════════════════════════════╣
║ Total Memory      : ${TOTAL_MEM}MB
║ Available         : ${AVAILABLE_MEM}MB
║ Heap Size         : ${HEAP_SIZE}MB
║ Max Heap (75%)    : ${MAX_HEAP}MB
║ Min Heap Required : ${MIN_HEAP}MB
║ Initial Heap      : $((HEAP_SIZE / 3))MB
╠═══════════════════════════════════════════════════════════════╣
║ CLI CAPABILITIES
╠═══════════════════════════════════════════════════════════════╣
║ CLI File               : $CLI_FILE
║ Supports --unsigned    : $SUPPORTS_UNSIGNED
║ Supports --rip-lib     : $SUPPORTS_RIP_LIB
╠═══════════════════════════════════════════════════════════════╣
║ BUILD OPTIONS
╠═══════════════════════════════════════════════════════════════╣
║ Source                 : $SOURCE
║ CLI Override Mode      : ${CLI_RIPLIB_ANTISPLIT:-off}
║ Rip Libs Status        : $RIP_LIBS_INFO
║ Signing                : $SIGNING_INFO
║ Custom Keystore Dir    : $(hasCustomKeystore && echo "Found" || echo "Not Found")
╠═══════════════════════════════════════════════════════════════╣
║ INPUT INFO
╠═══════════════════════════════════════════════════════════════╣
║ Format            : $FORMAT_INFO
║ Extension         : $INPUT_EXT
║ Input Path        : $INPUT_PATH
║ Output Path       : $OUTPUT_PATH
╠═══════════════════════════════════════════════════════════════╣
║ APP INFO
╠═══════════════════════════════════════════════════════════════╣
║ App Name          : $APP_NAME
║ App Version       : $APP_VER
║ Package           : $PKG_NAME
║ CLI               : $CLI_FILE
║ Patches           : $PATCHES_FILE
╠═══════════════════════════════════════════════════════════════╣
║ JVM ARGUMENTS
╠═══════════════════════════════════════════════════════════════╣
$(printf '║ %s\n' "${JAVA_ARGS[@]}")
╠═══════════════════════════════════════════════════════════════╣
║ RIP-LIBS ARGUMENTS
╠═══════════════════════════════════════════════════════════════╣
$(if [ ${#RIP_LIBS_ARGS[@]} -gt 0 ]; then printf '║ %s\n' "${RIP_LIBS_ARGS[@]}"; else echo "║ None"; fi)
╠═══════════════════════════════════════════════════════════════╣
║ SIGNING ARGUMENTS
╠═══════════════════════════════════════════════════════════════╣
$(printf '║ %s\n' "${SIGNING_ARGS[@]}")
╠═══════════════════════════════════════════════════════════════╣
║ PATCH ARGUMENTS
╠═══════════════════════════════════════════════════════════════╣
║ ${ARGUMENTS[*]}
╚═══════════════════════════════════════════════════════════════╝

========================= PATCHING LOGS =========================

EOF

    java \
        "${JAVA_ARGS[@]}" \
        -jar "$CLI_FILE" patch \
        --force --exclusive --purge --patches="$PATCHES_FILE" \
        --out="$OUTPUT_PATH" \
        "${SIGNING_ARGS[@]}" \
        "${RIP_LIBS_ARGS[@]}" \
        "${ARGUMENTS[@]}" \
        --custom-aapt2-binary="./bin/aapt2" \
        "$INPUT_PATH" 2>&1 |
        tee -a "$STORAGE/patch_log.txt" |
        "${DIALOG[@]}" \
            --ok-label 'Install & Save' \
            --extra-button \
            --extra-label 'Share Logs' \
            --cursor-off-label \
            --programbox "Patching $APP_NAME $APP_VER [$FORMAT_INFO | $GC_MODE | ${HEAP_SIZE}MB]" -1 -1

    EXIT_CODE=$?
    tput civis

    if [ $EXIT_CODE -eq 3 ]; then
        termux-open --send "$STORAGE/patch_log.txt"
    fi

    if grep -qE "OutOfMemoryError|Cannot allocate memory|GC overhead limit exceeded|Java heap space" "$STORAGE/patch_log.txt"; then
        "${DIALOG[@]}" \
            --title '| Memory Error |' \
            --msgbox "\nPatching failed due to memory error!\n\n  Total RAM   : ${TOTAL_MEM}MB\n  Available   : ${AVAILABLE_MEM}MB\n  Heap Used   : ${HEAP_SIZE}MB\n  GC Type     : ${GC_INFO}\n\nSuggestions:\n • Close all background apps\n • Restart Termux\n • Restart device\n • Try fewer patches" 18 55
        cleanupCliDetection
        return 1
    fi

    if [ $? -eq 1 ]; then
        termux-open --send "$STORAGE/patch_log.txt"
    fi

    if [ ! -f "$OUTPUT_PATH" ]; then
        notify msg "Patching failed !!\nInstallation Aborted.\n\nCheck logs for details."
        cleanupCliDetection
        return 1
    fi

    PATCH_SUCCESS=1
    cleanupCliDetection
    return 0
}
