#!/data/data/com.termux/files/usr/bin/bash
[ -z "$TERMUX_VERSION" ] && echo -e "Termux not detected !!" && exit 1
BIN="$PREFIX/bin/enhancify"
curl -sL "https://github.com/Graywizard888/Enhancify/raw/refs/heads/main/enhancify" -o "$BIN"
[ -e "$BIN" ] && sed -i "1s|.*|#!$PREFIX/bin/bash|" "$BIN" && chmod +x "$BIN" && "$BIN"
