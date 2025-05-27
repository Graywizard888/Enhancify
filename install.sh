#!/usr/bin/bash
[ -z "$TERMUX_VERSION" ] && echo -e "Termux not detected !!" && exit 1
BIN="$PREFIX/bin/revancify_Enhance"
curl -sL "https://github.com/Graywizard888/Revancify_Enhance/raw/refs/heads/main/revancify_Enhance" -o "$BIN"
[ -e "$BIN" ] && chmod +x "$BIN" && "$BIN"
