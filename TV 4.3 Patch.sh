bash << 'EOF'
set -e

TV="$HOME/.local/bin/tv"

echo ">>> Applying r-key mpv exit-code fix (no other changes)..."

perl -0777 -i -pe '
s{
mpv\s+--fullscreen[\s\S]*?\n\s*code=\$\?
}{
set +e
mpv --fullscreen --really-quiet --no-terminal --input-conf="\$INPUT_CONF" "\$URL" 2>/dev/null
code=\$?
set -e
}gx' "$TV"

chmod +x "$TV"

echo ">>> DONE. r now opens record dialog instead of exiting."
EOF
