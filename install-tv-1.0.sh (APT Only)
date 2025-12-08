#!/usr/bin/env bash
#
# install-tv.sh - Simple TV launcher installer for Ubuntu-based distros
# - Installs mpv + curl via apt
# - Downloads tvpass playlist to ~/TV/playlist.m3u
# - Installs "tv" command in ~/.local/bin
# - Adds a "TV" menu icon (tv.desktop)

set -e

echo ">>> Checking for apt..."
if ! command -v apt >/dev/null 2>&1; then
  echo "This installer requires an apt-based system (Ubuntu, Mint, etc.)."
  exit 1
fi

echo ">>> Updating package list and installing mpv + curl..."
sudo apt update
sudo apt install -y mpv curl

TV_DIR="$HOME/TV"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
PLAYLIST="$TV_DIR/playlist.m3u"
TVPASS_URL="https://tvpass.org/playlist/m3u"

echo ">>> Creating directories..."
mkdir -p "$TV_DIR" "$BIN_DIR" "$APP_DIR"

echo ">>> Downloading playlist from tvpass.org..."
curl -L "$TVPASS_URL" -o "$PLAYLIST"

echo ">>> Writing tv command to $BIN_DIR/tv ..."
cat > "$BIN_DIR/tv" << 'EOF'
#!/usr/bin/env bash
#
# TV channel picker for mpv using tvpass playlist
# Usage:
#   tv        -> list channels & pick number to play
#   tv update -> refresh playlist from tvpass.org

PLAYLIST="$HOME/TV/playlist.m3u"
TVPASS_URL="https://tvpass.org/playlist/m3u"

ensure_playlist() {
  if [ ! -f "$PLAYLIST" ]; then
    echo "Playlist missing — downloading..."
    curl -L "$TVPASS_URL" -o "$PLAYLIST" || {
      echo "❌ Failed to download playlist."
      exit 1
    }
  fi
}

update_playlist() {
  echo "⟳ Updating playlist..."
  curl -L "$TVPASS_URL" -o "$PLAYLIST" && echo "✔ Playlist updated."
  exit 0
}

tv_menu() {
  ensure_playlist

  command -v mpv >/dev/null || { echo "❌ mpv not installed"; exit 1; }

  TMP="$(mktemp)"

  # Parse playlist → index  name  url
  awk -v OFS='\t' '
    BEGIN{n=0;name=""}
    /^#EXTINF/{
      sub(/.*,/, "", $0); name=$0; next
    }
    /^https?:\/\//{
      n++; print n, (name==""?"Unknown":name), $0; name=""
    }
  ' "$PLAYLIST" > "$TMP"

  [ ! -s "$TMP" ] && { echo "❌ No channels found."; rm -f "$TMP"; exit 1; }

  COLS="$(tput cols 2>/dev/null || echo 80)"

  while true; do
    clear
    echo "==================== TV CHANNELS ===================="
    echo " Type a number → channel plays in MPV"
    echo " After it closes → list appears again"
    echo ' Press ENTER with no input to exit'
    echo "====================================================="
    echo

    awk -F'\t' '{print $1". "$2}' "$TMP" | column -c "$COLS"
    echo
    read -rp "Channel #: " CH

    [ -z "$CH" ] && break
    printf '%s\n' "$CH" | grep -Eq '^[0-9]+$' || { echo "Numbers only"; sleep 1; continue; }

    URL="$(awk -F'\t' -v i="$CH" '$1==i{print $3}' "$TMP")"
    NAME="$(awk -F'\t' -v i="$CH" '$1==i{print $2}' "$TMP")"

    if [ -z "$URL" ]; then
      echo "Invalid channel #"
      sleep 1
      continue
    fi

    echo
    echo "▶ Playing CH $CH: $NAME"
    echo

    mpv --title="CH $CH - $NAME" "$URL"
    # when mpv exits, loop continues
  done

  rm -f "$TMP"
  echo "Exited TV"
}

case "$1" in
  update) update_playlist ;;
  ""|list) tv_menu ;; # tv or tv list
  *) tv_menu ;;
esac
EOF

chmod +x "$BIN_DIR/tv"

echo ">>> Ensuring ~/.local/bin is in your PATH..."
if ! printf '%s\n' "$PATH" | grep -q "$HOME/.local/bin" ; then
  # Add to both bashrc and profile for widest coverage
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"
  echo "Added ~/.local/bin to PATH in ~/.bashrc and ~/.profile."
fi

echo ">>> Creating tv.desktop launcher..."
cat > "$APP_DIR/tv.desktop" << 'EOF'
[Desktop Entry]
Name=TV
Comment=Terminal TV channel launcher
Exec=x-terminal-emulator -e bash -lc "tv; exec bash"
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=AudioVideo;Entertainment;
EOF

chmod +x "$APP_DIR/tv.desktop"

# Refresh desktop database if tool exists
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APP_DIR" || true
fi

echo
echo "==============================================="
echo "✔ Installation complete."
echo "You can now:"
echo "  • Run 'tv' in a new terminal to open the channel list"
echo "  • Find 'TV' in your app menu and pin it to favorites/desktop"
echo
echo "Commands:"
echo "  tv         → channel list, type number, plays via mpv"
echo "  tv update  → refresh playlist from tvpass.org"
echo "==============================================="
