#!/usr/bin/bash

MIN_HEAP=1024
CUSTOM_KEYSTORE_DIR="$HOME/Enhancify/keystore"
CLI_DETECTION_FILE="$HOME/Enhancify/cli_detection.json"
SUPPORTED_EXTENSIONS=("apk" "apkm" "xapk" "apks")

USE_PARALLEL_GC="${USE_PARALLEL_GC:-off}"

_SYS_JAVA_VER=0
_SYS_JAVA_FULL_VER=""
_SYS_AVAIL_MEM=1024
_SYS_TOTAL_MEM=0
_SYS_DEVICE_ARCH="arm64-v8a"

_BUILT_CPU_CORES=4

initSystemInfo() {
    local RAW_JAVA
    RAW_JAVA=$(java -version 2>&1)
    _SYS_JAVA_FULL_VER="${RAW_JAVA%%$'\n'*}"
    local _tmp="${RAW_JAVA#*\"}"
    _tmp="${_tmp%%\"*}"
    _SYS_JAVA_VER="${_tmp%%.*}"
    _SYS_JAVA_VER="${_SYS_JAVA_VER//[!0-9]/}"
    [[ -z "$_SYS_JAVA_VER" ]] && _SYS_JAVA_VER=0

    local FREE_OUT
    FREE_OUT=$(free -m 2>/dev/null)
    read -r _SYS_TOTAL_MEM _SYS_AVAIL_MEM < <(
        awk '/^Mem:/{print $2, ($7+0 > 0 ? $7 : $4)}' <<< "$FREE_OUT"
    )
    [[ -z "$_SYS_AVAIL_MEM" ]] && _SYS_AVAIL_MEM=1024
    [[ -z "$_SYS_TOTAL_MEM" ]] && _SYS_TOTAL_MEM=0

    local ARCH_RAW
    ARCH_RAW=$(getprop ro.product.cpu.abi 2>/dev/null)
    case "$ARCH_RAW" in
        arm64-v8a|arm64*)            _SYS_DEVICE_ARCH="arm64-v8a"   ;;
        armeabi-v7a|armeabi*|armv7*) _SYS_DEVICE_ARCH="armeabi-v7a" ;;
        *)                           _SYS_DEVICE_ARCH="arm64-v8a"   ;;
    esac
}

isSupportedJava() {
    [[ "$_SYS_JAVA_VER" -eq 17 || "$_SYS_JAVA_VER" -eq 21 || "$_SYS_JAVA_VER" -eq 25 ]]
}

isLowMemory() {
    [[ "$_SYS_AVAIL_MEM" -lt "$MIN_HEAP" ]]
}

shouldUseCliOverride() {
    [[ "$CLI_RIPLIB_ANTISPLIT" == "on" ]]
}

hasCustomKeystore() {
    [[ -d "$CUSTOM_KEYSTORE_DIR" ]]
}

isApp() {
    [[ "${APP_NAME,,}" == *reddit* || "${APP_NAME,,}" == *instagram* ]]
}

hasMppPatches() {
    [[ ! -d "assets/$SOURCE" ]] && return 1

    local MPP_FILES
    MPP_FILES=$(ls "assets/$SOURCE"/Patches-*.mpp 2>/dev/null)
    [[ -z "$MPP_FILES" ]] && return 1

    return 0
}

getApkExtension() {
    local APP_DIR="apps/$APP_NAME"
    for ext in "${SUPPORTED_EXTENSIONS[@]}"; do
        [[ -f "$APP_DIR/$APP_VER.$ext" ]] && { echo "$ext"; return 0; }
    done
    return 1
}

getOutputApkPath() {
    echo "apps/$APP_NAME/$APP_VER-$SOURCE.apk"
}

isSplitApk() {
    case "$1" in
        apkm|xapk|apks) return 0 ;;
        *)               return 1 ;;
    esac
}

getApkFormatInfo() {
    case "$1" in
        apk)  echo "Standard APK"     ;;
        apkm) echo "Split APK (APKM)" ;;
        xapk) echo "Split APK (XAPK)" ;;
        apks) echo "Split APK (APKS)" ;;
        *)    echo "Unknown"           ;;
    esac
}

getRipLibsArgs() {
    local KEEP="$1"
    local ALL_ARCHS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
    for arch in "${ALL_ARCHS[@]}"; do
        [[ "$arch" != "$KEEP" ]] && echo "--rip-lib=$arch"
    done
}

getStripLibsArgs() {
    echo "--striplibs=$1"
}

purgeKeystore() {
    rm -f "$STORAGE/revancify.keystore" 2>/dev/null
}

loadCliCapabilities() {
    [[ ! -f "$CLI_DETECTION_FILE" ]] && cli_arg_detector >/dev/null 2>&1

    if [[ -f "$CLI_DETECTION_FILE" ]]; then
        SUPPORTS_UNSIGNED=$(jq -r '.unsigned // false' "$CLI_DETECTION_FILE" 2>/dev/null || echo "false")
        SUPPORTS_RIP_LIB=$(jq -r '.riplib // false'   "$CLI_DETECTION_FILE" 2>/dev/null || echo "false")
        SUPPORTS_STRIP_LIBS=$(jq -r '.striplibs // false' "$CLI_DETECTION_FILE" 2>/dev/null || echo "false")
    else
        SUPPORTS_UNSIGNED="false"
        SUPPORTS_RIP_LIB="false"
        SUPPORTS_STRIP_LIBS="false"
    fi
    export SUPPORTS_UNSIGNED SUPPORTS_RIP_LIB SUPPORTS_STRIP_LIBS
}

cleanupCliDetection() {
    rm -f "$CLI_DETECTION_FILE" 2>/dev/null
}

checkMemory() {
    if isLowMemory; then
        "${DIALOG[@]}" \
            --title '| Low Memory Warning |' \
            --yesno "\nLow memory detected!\n\n  Available : ${_SYS_AVAIL_MEM}MB\n  Required  : ${MIN_HEAP}MB\n\nPatching may fail due to insufficient memory.\nSerial GC will be used for better stability.\n\nRecommendations:\n • Close background apps\n • Restart Termux\n • Free up RAM\n\nDo you still want to continue anyway?" 20 50
        case "$?" in
            0) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

checkParallelGCConditions() {
    [[ "$USE_PARALLEL_GC" != "on" ]] && return 1
    isSupportedJava || return 2
    isLowMemory && return 3
    return 0
}

getParallelGCFailReason() {
    if ! isSupportedJava; then
        echo "Java $_SYS_JAVA_VER detected (requires 17, 21, or 25)"
    elif isLowMemory; then
        echo "Low memory: ${_SYS_AVAIL_MEM}MB (requires ${MIN_HEAP}MB)"
    else
        echo "Unknown condition failed"
    fi
}

buildParallelGCArgs() {
    local HEAP_SIZE="$1"
    local INITIAL_HEAP=$((HEAP_SIZE / 2))

    _BUILT_CPU_CORES=$(nproc 2>/dev/null || echo 4)

    JAVA_ARGS=(
        "-Djava.awt.headless=true"
        "-Dfile.encoding=UTF-8"
        "-Djava.io.tmpdir=$TMPDIR"
        "-Xmx${HEAP_SIZE}m"
        "-Xms${INITIAL_HEAP}m"
        "-Xss500k"
        "-XX:+UseParallelGC"
        "-XX:ParallelGCThreads=$_BUILT_CPU_CORES"
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
        "-XX:+UseTLAB"
        "-XX:MinHeapFreeRatio=20"
        "-XX:MaxHeapFreeRatio=40"
        "-XX:SoftRefLRUPolicyMSPerMB=50"
        "-XX:+UseGCOverheadLimit"
        "-XX:GCTimeLimit=90"
        "-XX:GCHeapFreeLimit=10"
        "-XX:+ParallelRefProcEnabled"
        "-XX:+DisableExplicitGC"
        "-XX:+TieredCompilation"
        "-XX:CICompilerCount=3"
        "-XX:CompileThreshold=1000"
        "-XX:+OptimizeStringConcat"
        "-XX:MaxInlineSize=100"
        "-XX:FreqInlineSize=200"
        "-XX:-UsePerfData"
    )

    if isSupportedJava; then
        JAVA_ARGS+=(
            "--add-opens=java.base/java.lang=ALL-UNNAMED"
            "--add-opens=java.base/java.util=ALL-UNNAMED"
            "--add-opens=java.base/java.io=ALL-UNNAMED"
            "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED"
            "--add-opens=java.base/java.nio=ALL-UNNAMED"
        )
    fi
}

buildJavaArgs() {
    local HEAP_SIZE="$1"

    _BUILT_CPU_CORES=$(nproc 2>/dev/null || echo 4)

    local CONC_GC_THREADS=$((_BUILT_CPU_CORES / 4))
    (( CONC_GC_THREADS < 2 )) && CONC_GC_THREADS=2

    JAVA_ARGS=(
        "-Djava.awt.headless=true"
        "-Xmx${HEAP_SIZE}m"
        "-Xms$((HEAP_SIZE / 2))m"
        "-Djava.io.tmpdir=$TMPDIR"
        "-XX:-UsePerfData"
        "-Dfile.encoding=UTF-8"
    )

    if isSupportedJava; then
        JAVA_ARGS+=(
            "-XX:+UseG1GC"
            "-XX:MaxGCPauseMillis=150"
            "-XX:G1HeapRegionSize=2m"
            "-XX:+UseStringDeduplication"
            "-XX:+ParallelRefProcEnabled"
            "-XX:ConcGCThreads=$CONC_GC_THREADS"
            "-XX:ParallelGCThreads=$_BUILT_CPU_CORES"
            "-XX:CICompilerCount=3"
            "-XX:+UseCompressedOops"
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
}

buildLightweightJavaArgs() {
    local HEAP_SIZE="$1"

    _BUILT_CPU_CORES=1

    JAVA_ARGS=(
        "-Djava.awt.headless=true"
        "-Xmx${HEAP_SIZE}m"
        "-Xms$((HEAP_SIZE / 2))m"
        "-Dfile.encoding=UTF-8"
        "-Djava.io.tmpdir=$TMPDIR"
        "-XX:+UseSerialGC"
        "-XX:TieredStopAtLevel=1"
        "-XX:+UseCompressedOops"
        "-XX:-UsePerfData"
        "-XX:CICompilerCount=1"
        "-XX:ReservedCodeCacheSize=32m"
    )

    if isSupportedJava; then
        JAVA_ARGS+=(
            "--add-opens=java.base/java.lang=ALL-UNNAMED"
            "--add-opens=java.base/java.util=ALL-UNNAMED"
            "--add-opens=java.base/java.io=ALL-UNNAMED"
        )
    fi
}

findPatchedApp() {
    local OUTPUT_PATH
    OUTPUT_PATH=$(getOutputApkPath)
    if [[ -e "$OUTPUT_PATH" ]]; then
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
    fi
    return 0
}

writeLogHeader() {
    local LOG_FILE="$1"
    local fd
    exec {fd}>"$LOG_FILE"

    printf '%s\n' \
        "╔═══════════════════════════════════════════════════════════════╗" \
        "║                     Enhancify PATCH LOG" \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ Date: $(date)" \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ SYSTEM INFO" \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ Root Access       : $ROOT_ACCESS" \
        "║ Rish Access       : $RISH_ACCESS" \
        "║ Device Arch       : $DEVICE_ARCH" \
        "║ CPU Cores         : $_BUILT_CPU_CORES" >&"$fd"

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ JAVA INFO" \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ Java Version        : $_SYS_JAVA_FULL_VER" \
        "║ Major Version       : $_SYS_JAVA_VER" \
        "║ GC Type             : $GC_INFO" \
        "║ GC Mode             : $GC_MODE" \
        "║ Low Memory Override : $LOW_MEM_OVERRIDE" >&"$fd"

    [[ -n "$GC_OVERRIDE_MSG" ]] && printf '%s\n' "║ GC Override       : $GC_OVERRIDE_MSG" >&"$fd"

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ MEMORY INFO" \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ Total Memory      : ${_SYS_TOTAL_MEM}MB" \
        "║ Available         : ${_SYS_AVAIL_MEM}MB" \
        "║ Heap Size (75%)   : ${HEAP_SIZE}MB" \
        "║ Min Heap Required : ${MIN_HEAP}MB" \
        "║ Initial Heap      : $((HEAP_SIZE / 2))MB" >&"$fd"

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ CLI CAPABILITIES" \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ CLI File               : $CLI_FILE" \
        "║ Supports --unsigned    : $SUPPORTS_UNSIGNED" \
        "║ Supports --rip-lib     : $SUPPORTS_RIP_LIB" \
        "║ Supports --striplibs   : $SUPPORTS_STRIP_LIBS" >&"$fd"

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ BUILD OPTIONS" \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ Source                    : $SOURCE" \
        "║ CLI Override Mode         : ${CLI_RIPLIB_ANTISPLIT:-off}" \
        "║ Lib Optimize Method       : $LIB_OPTIMIZE_METHOD" \
        "║ Lib Optimize Status       : $LIB_OPTIMIZE_INFO" \
        "║ Bytecode Mode             : $BYTECODE_MODE_INFO" \
        "║ Signing                   : $SIGNING_INFO" >&"$fd"

    if hasCustomKeystore; then
        printf '%s\n' "║ Custom Keystore Dir       : Found" >&"$fd"
    else
        printf '%s\n' "║ Custom Keystore Dir       : Not Found" >&"$fd"
    fi

    printf '%s\n' \
        "║ Signature Verification    : $VERIFICATION_INFO" \
        "║ Custom AAPT2              : $AAPT2_INFO" >&"$fd"

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ APP INFO" \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ App Name          : $APP_NAME" \
        "║ App Version       : $APP_VER" \
        "║ Package           : $PKG_NAME" \
        "║ CLI               : $CLI_FILE" \
        "║ Patches           : $PATCHES_FILE" >&"$fd"

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ JVM ARGUMENTS" \
        "╠═══════════════════════════════════════════════════════════════╣" >&"$fd"

    printf '║ %s\n' "${JAVA_ARGS[@]}" >&"$fd"

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ LIB OPTIMIZATION ARGUMENTS" \
        "╠═══════════════════════════════════════════════════════════════╣" >&"$fd"

    if (( ${#LIB_OPTIMIZE_ARGS[@]} )); then
        printf '║ %s\n' "${LIB_OPTIMIZE_ARGS[@]}" >&"$fd"
    else
        printf '║ None\n' >&"$fd"
    fi

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ BYTECODE MODE ARGUMENTS" \
        "╠═══════════════════════════════════════════════════════════════╣" >&"$fd"

    if (( ${#BYTECODE_MODE_ARGS[@]} )); then
        printf '║ %s\n' "${BYTECODE_MODE_ARGS[@]}" >&"$fd"
    else
        printf '║ None\n' >&"$fd"
    fi

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ SIGNING ARGUMENTS" \
        "╠═══════════════════════════════════════════════════════════════╣" >&"$fd"

    printf '║ %s\n' "${SIGNING_ARGS[@]}" >&"$fd"

    printf '%s\n' \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ PATCH ARGUMENTS" \
        "╠═══════════════════════════════════════════════════════════════╣" \
        "║ ${ARGUMENTS[*]}" \
        "╚═══════════════════════════════════════════════════════════════╝" \
        "" \
        "========================= PATCHING LOGS =========================" \
        "" >&"$fd"

    exec {fd}>&-
}

patchApp() {
    local INPUT_EXT INPUT_PATH OUTPUT_PATH FORMAT_INFO
    local PATCH_SUCCESS=0 GC_OVERRIDE_MSG="" LOW_MEM_OVERRIDE=false

    INPUT_EXT=$(getApkExtension)
    if [[ -z "$INPUT_EXT" ]]; then
        notify msg "APK not found !!\nSupported formats: APK, APKM, XAPK, APKS\nTry importing from Storage."
        return 1
    fi

    INPUT_PATH="apps/$APP_NAME/$APP_VER.$INPUT_EXT"
    OUTPUT_PATH=$(getOutputApkPath)
    FORMAT_INFO=$(getApkFormatInfo "$INPUT_EXT")

    if [[ ! -e "$INPUT_PATH" ]]; then
        notify msg "APK not found !!\nTry importing APK from Storage."
        return 1
    fi

    purgeKeystore

    initSystemInfo

    if ! isSupportedJava; then
        "${DIALOG[@]}" \
            --title '| Java Version Warning |' \
            --yesno "\nUnsupported Java version detected!\n\nDetected: Java $_SYS_JAVA_VER\nSupported: OpenJDK 17, 21, or 25\n\nScript is optimized for OpenJDK 17/21/25.\nContinue with current Java?" 14 50
        [[ $? -ne 0 ]] && return 1
    fi

    if ! checkMemory; then
        notify msg "Patching cancelled due to low memory."
        return 1
    fi

    local HEAP_SIZE=$((_SYS_AVAIL_MEM * 75 / 100))
    (( HEAP_SIZE < MIN_HEAP )) && HEAP_SIZE=$MIN_HEAP

    local GC_MODE="G1 Engine" GC_INFO="G1GC (Default)" GC_TYPE=""

    if isLowMemory; then
        LOW_MEM_OVERRIDE=true
        buildLightweightJavaArgs "$HEAP_SIZE"
        GC_MODE="Serial Engine"
        GC_INFO="SerialGC (Low Memory Fallback)"
        GC_TYPE="SerialGC"
        GC_OVERRIDE_MSG="Low memory detected (${_SYS_AVAIL_MEM}MB < ${MIN_HEAP}MB) - Forced Serial GC for stability"

    elif [[ "$USE_PARALLEL_GC" == "on" ]]; then
        if checkParallelGCConditions; then
            buildParallelGCArgs "$HEAP_SIZE"
            GC_MODE="Parallel Engine"
            GC_INFO="ParallelGC (Enabled)"
            GC_TYPE="ParallelGC"
        else
            local FAIL_REASON
            FAIL_REASON=$(getParallelGCFailReason)
            notify msg "Parallel GC conditions not met\n$FAIL_REASON\n\nOverriding to G1GC"
            buildJavaArgs "$HEAP_SIZE"
            GC_MODE="G1 Engine"
            GC_INFO="G1GC (Parallel GC Override - $FAIL_REASON)"
            GC_TYPE="G1GC"
            GC_OVERRIDE_MSG="Parallel GC requested but conditions not met: $FAIL_REASON"
        fi

    else
        buildJavaArgs "$HEAP_SIZE"
        GC_TYPE="G1GC"
    fi

    local DEVICE_ARCH="$_SYS_DEVICE_ARCH"
    local LIB_OPTIMIZE_ARGS=() LIB_OPTIMIZE_INFO="Disabled" LIB_OPTIMIZE_METHOD="None"

    if shouldUseCliOverride; then
        loadCliCapabilities

        if [[ "$SUPPORTS_STRIP_LIBS" == "true" ]]; then
            readarray -t LIB_OPTIMIZE_ARGS < <(getStripLibsArgs "$DEVICE_ARCH")
            LIB_OPTIMIZE_INFO="CLI Override: Enabled (Keeping $DEVICE_ARCH)"
            LIB_OPTIMIZE_METHOD="--striplibs"
        elif [[ "$SUPPORTS_RIP_LIB" == "true" ]]; then
            readarray -t LIB_OPTIMIZE_ARGS < <(getRipLibsArgs "$DEVICE_ARCH")
            LIB_OPTIMIZE_INFO="CLI Override: Enabled (Keeping $DEVICE_ARCH)"
            LIB_OPTIMIZE_METHOD="--rip-lib"
        else
            LIB_OPTIMIZE_INFO="CLI Override: Not Supported by $SOURCE CLI"
        fi
    else
        LIB_OPTIMIZE_INFO="Optimize Libs: $DEVICE_ARCH"
        LIB_OPTIMIZE_METHOD="Native (Inbuild)"
    fi

    local BYTECODE_MODE_ARGS=() BYTECODE_MODE_INFO="Disabled"
    
    if hasMppPatches; then
        case "$GC_TYPE" in
            SerialGC)
                BYTECODE_MODE_ARGS=("--bytecode-mode=STRIP_FAST")
                BYTECODE_MODE_INFO="STRIP_FAST (SerialGC Optimized)"
                ;;
            ParallelGC|G1GC)
                BYTECODE_MODE_ARGS=("--bytecode-mode=STRIP_SAFE")
                BYTECODE_MODE_INFO="STRIP_SAFE ($GC_TYPE Optimized)"
                ;;
            *)
                BYTECODE_MODE_INFO="Cli Default (Unknown GC Type)"
                ;;
        esac
    else
        BYTECODE_MODE_INFO="Disabled (Not Morphe Compatible source)"
    fi

    local SIGNING_ARGS=() SIGNING_INFO
    if shouldUseCliOverride && [[ "$SUPPORTS_UNSIGNED" == "true" ]] && hasCustomKeystore; then
        SIGNING_ARGS=("--unsigned")
        SIGNING_INFO="Unsigned (Custom keystore will be used)"
    else
        SIGNING_ARGS=("--keystore=$STORAGE/revancify.keystore")
        if shouldUseCliOverride && [[ "$SUPPORTS_UNSIGNED" == "true" ]] && ! hasCustomKeystore; then
            SIGNING_INFO="CLI keystore (No custom keystore found)"
        elif shouldUseCliOverride && [[ "$SUPPORTS_UNSIGNED" != "true" ]]; then
            SIGNING_INFO="CLI keystore (--unsigned not supported by $SOURCE)"
        elif ! shouldUseCliOverride; then
            SIGNING_INFO="CLI keystore (CLI override disabled)"
        else
            SIGNING_INFO="CLI keystore"
        fi
    fi

    local VERIFICATION_ARGS=() VERIFICATION_INFO="None Detected"
    if [[ "$SOURCE" == "ReVanced" ]]; then
        VERIFICATION_ARGS=("--bypass-verification")
        VERIFICATION_INFO="Force Signature Verification Bypassed"
    fi

    local AAPT2_ARGS=() AAPT2_INFO="CLI aapt2"
    if ! isApp; then
        AAPT2_ARGS=("--custom-aapt2-binary=./bin/aapt2")
        AAPT2_INFO="Inbuild aapt2"
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

    writeLogHeader "$STORAGE/patch_log.txt"

    java \
        "${JAVA_ARGS[@]}" \
        -jar "$CLI_FILE" patch \
        --force --exclusive --purge --patches="$PATCHES_FILE" \
        --out="$OUTPUT_PATH" \
        "${SIGNING_ARGS[@]}" \
        "${VERIFICATION_ARGS[@]}" \
        "${LIB_OPTIMIZE_ARGS[@]}" \
        "${BYTECODE_MODE_ARGS[@]}" \
        "${AAPT2_ARGS[@]}" \
        "${ARGUMENTS[@]}" \
        "$INPUT_PATH" 2>&1 |
        tee >(dd bs=64K >> "$STORAGE/patch_log.txt" 2>/dev/null) |
        "${DIALOG[@]}" \
            --ok-label 'Install & Save' \
            --extra-button \
            --extra-label 'Share Logs' \
            --cursor-off-label \
            --programbox "Patching $APP_NAME $APP_VER [$FORMAT_INFO | JDK $_SYS_JAVA_VER | $GC_MODE | ${HEAP_SIZE}MB]" -1 -1

    EXIT_CODE=$?
    tput civis

    if [[ $EXIT_CODE -eq 3 ]]; then
        termux-open --send "$STORAGE/patch_log.txt"
    fi

    if grep -qF -e "OutOfMemoryError" -e "Cannot allocate memory" -e "GC overhead limit exceeded" -e "Java heap space" "$STORAGE/patch_log.txt"; then
        "${DIALOG[@]}" \
            --title '| Memory Error |' \
            --msgbox "\nPatching failed due to memory error!\n\n  Total RAM   : ${_SYS_TOTAL_MEM}MB\n  Available   : ${_SYS_AVAIL_MEM}MB\n  Heap Used   : ${HEAP_SIZE}MB\n  GC Type     : ${GC_INFO}\n\nSuggestions:\n • Close all background apps\n • Restart Termux\n • Restart device\n • Try fewer patches" 18 55
        cleanupCliDetection
        return 1
    fi

    if [[ $EXIT_CODE -eq 1 ]]; then
        termux-open --send "$STORAGE/patch_log.txt"
    fi

    if [[ ! -f "$OUTPUT_PATH" ]]; then
        notify msg "Patching failed !!\nInstallation Aborted.\n\nCheck logs for details."
        cleanupCliDetection
        return 1
    fi

    PATCH_SUCCESS=1
    cleanupCliDetection
    return 0
}
