bash << 'EOF'
set -euo pipefail

echo "============================================"
echo " TV 4.3 FINAL (Restored 4.1 + Locked Changes)"
echo "============================================"

# ---- deps
if ! command -v apt >/dev/null 2>&1; then
  echo "This installer expects an apt-based distro (Mint/Ubuntu)."
  exit 1
fi

echo ">>> Installing dependencies..."
sudo apt update
sudo apt install -y mpv curl fzf ffmpeg python3 thunar

TV_DIR="$HOME/TV"
mkdir -p "$TV_DIR" "$HOME/.local/bin" "$HOME/.local/share/applications"

cat > "$HOME/.local/bin/tv" << 'TVEOF'
#!/usr/bin/env bash
# TV 4.3 FINAL
# - Restores TV 4.1 core behavior (the "masterpiece")
# - Commits locked changes:
#   1) ALL fzf screens fullscreen
#   2) Watching/buffering screen shows 4 time blocks as 12h local time
#   3) Guides restored in 4.1 spirit + upgrades:
#      - Quick Guide: all channels, NOW + 3 blocks; click NOW=play; click future=record single/series
#      - 24 Hour Guide: channel list -> 24h lineup -> info -> record single(+30)/series
#   4) Press r while watching => record dialog (Live / Series / This episode +30 / Back)
# - Hides mpv spam (no red error vomit)
# - Shows loading screens during heavy work

set -euo pipefail

#########################################
# PATHS / URLS
#########################################
TV_DIR="$HOME/TV"

# TVpass
PLAYLIST="$TV_DIR/playlist.m3u"
EPG="$TV_DIR/epg.xml"
TVPASS_PLS="https://tvpass.org/playlist/m3u"
TVPASS_EPG="https://tvpass.org/epg.xml"

# Global (iptv-org)
MAIN_PLAYLIST="$TV_DIR/main.m3u"
GLOBAL_INDEX="$TV_DIR/global-index.m3u"
MAIN_URL="https://iptv-org.github.io/iptv/countries/us.m3u"
GLOBAL_INDEX_URL="https://iptv-org.github.io/iptv/index.m3u"

# Runtime
INPUT_CONF="$TV_DIR/tv-input.conf"
RECDIR="$TV_DIR/recordings"
REC_PIDFILE="$TV_DIR/recording.pid"
TIMERS_DB="$TV_DIR/timers.db"

# Caches
NOW_CACHE="$TV_DIR/now-cache.txt"           # num \t name \t now-title
EPG4_CACHE="$TV_DIR/epg-four.txt"           # num \t t1 \t title1 \t t2 \t title2 \t t3 \t title3 \t t4 \t title4
QGUIDE_CACHE="$TV_DIR/quick-guide.txt"      # display rows for quick guide
GUIDE24_MAP="$TV_DIR/guide24-map.tsv"       # per-channel day map: st \t en \t label \t title

mkdir -p "$TV_DIR" "$RECDIR"

#########################################
# FZF: FORCE FULLSCREEN LOOK
#########################################
export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS:-} --height=100% --layout=reverse --border --info=inline --prompt='> '"

clock12() { date '+%-I:%M %p'; }

loading_screen() {
  clear
  echo "╔════════════════════════════════════════╗"
  printf "║ ⏳  TV ▸ Loading...        %-10s ║\n" "$(clock12)"
  echo "╚════════════════════════════════════════╝"
  echo
  echo "  🧠 Building guide caches..."
  echo "  📺 This can take a moment on first load."
  echo
}

#########################################
# MPV INPUT CONF
#########################################
ensure_input_conf() {
  cat > "$INPUT_CONF" << 'EOT'
ctrl+UP no-osd quit 3
ctrl+DOWN no-osd quit 4
1 no-osd quit 5
r no-osd quit 5
EOT
}

#########################################
# TVPASS FETCH
#########################################
tvpass_ensure_playlist() {
  if [ ! -s "$PLAYLIST" ]; then
    clear
    echo ">>> Downloading TVpass playlist..."
    curl -sS -L "$TVPASS_PLS" -o "$PLAYLIST"
  fi
}
tvpass_ensure_guide() {
  if [ ! -s "$EPG" ]; then
    clear
    echo ">>> Downloading TVpass EPG..."
    curl -sS -L "$TVPASS_EPG" -o "$EPG"
  fi
}
tvpass_update_all() {
  clear
  echo "⟳ Updating TVpass playlist + guide..."
  curl -sS -L "$TVPASS_PLS" -o "$PLAYLIST"
  curl -sS -L "$TVPASS_EPG" -o "$EPG"
  echo "✔ Done."
  exit 0
}

#########################################
# TVPASS CHANNEL TABLE (first 177)
#########################################
build_table() {
  local TMP
  TMP=$(mktemp)
  awk -v OFS='\t' '
    BEGIN{n=0; name=""}
    /^#EXTINF/{
      sub(/.*,/, "", $0); name=$0; next
    }
    /^http/{
      if (n >= 177) next
      n++; print n, (name==""?"Unknown":name), $0; name=""
    }
  ' "$PLAYLIST" > "$TMP"
  echo "$TMP"
}

#########################################
# EPG CACHES:
# - NOW_CACHE
# - EPG4_CACHE with 12h times + titles (4 blocks)
# - Quick Guide display rows (NOW + 3)
#########################################
build_epg_caches() {
  local TABLE="$1"
  : > "$NOW_CACHE"
  : > "$EPG4_CACHE"
  : > "$QGUIDE_CACHE"

  python3 - "$EPG" "$TABLE" "$NOW_CACHE" "$EPG4_CACHE" "$QGUIDE_CACHE" << 'PY'
import sys, re
from datetime import datetime
import xml.etree.ElementTree as ET

epg_path, table_path, now_path, epg4_path, qg_path = sys.argv[1:]

tree = ET.parse(epg_path)
root = tree.getroot()

def canon_name(s: str) -> str:
    s = s or ""
    s = re.sub(r"\[[^\]]*\]", " ", s)
    s = re.sub(r"\([^)]*\)", " ", s)
    s = re.sub(r"[-–_|]", " ", s)
    for token in ["HD","East","West","US","USA","Feed","TV","Channel","Network","Latino"]:
        s = re.sub(r"\b"+re.escape(token)+r"\b"," ",s,flags=re.I)
    s = re.sub(r"\s+"," ",s).strip().lower()
    return s

channels=[]
for ch in root.findall("channel"):
    cid=ch.get("id","")
    names=[dn.text.strip() for dn in ch.findall("display-name") if dn.text]
    channels.append((cid,names))

def find_channel_id(name):
    name=(name or "").strip()
    if not name: return None
    for cid,names in channels:
        for dn in names:
            if dn == name:
                return cid
    short=canon_name(name)
    if not short: return None
    for cid,names in channels:
        joined=" ".join(n for n in names if n)
        if short and short in canon_name(joined):
            return cid
    return None

progs_by_id={}
for p in root.findall("programme"):
    cid=p.get("channel")
    if not cid: continue
    progs_by_id.setdefault(cid,[]).append(p)

def parse_dt(s):
    if not s: return None
    for fmt in ("%Y%m%d%H%M%S %z","%Y%m%d%H%M%S%z"):
        try:
            return datetime.strptime(s,fmt).astimezone()
        except:
            pass
    return None

now = datetime.now().astimezone()

def next_blocks(cid, limit=4):
    out=[]
    for p in progs_by_id.get(cid,[]):
        st=parse_dt(p.get("start"))
        en=parse_dt(p.get("stop"))
        if not st or not en: continue
        if en <= now: continue
        t_el=p.find("title")
        title=(t_el.text.strip() if (t_el is not None and t_el.text) else "")
        if title:
            out.append((st,en,title))
        if len(out)>=limit: break
    return out

with open(table_path,"r",encoding="utf-8") as tf, \
     open(now_path,"w",encoding="utf-8") as nf, \
     open(epg4_path,"w",encoding="utf-8") as ef, \
     open(qg_path,"w",encoding="utf-8") as qg:

    for line in tf:
        parts=line.rstrip("\n").split("\t")
        if len(parts)<3: continue
        num,name,url=parts[0],parts[1],parts[2]
        cid=find_channel_id(name)
        if not cid: 
            continue
        blocks=next_blocks(cid,4)
        if not blocks:
            continue

        # NOW title
        nf.write(f"{num}\t{name}\t{blocks[0][2]}\n")

        # EPG4: time + title pairs
        cols=[num]
        for st,en,title in blocks[:4]:
            cols += [st.strftime("%-I:%M %p"), title]
        while len(cols) < 1+8:
            cols += ["",""]
        ef.write("\t".join(cols[:9])+"\n")

        # Quick Guide row: ONE channel line + NOW + 3 upcoming blocks
        # [ 17] 📺 Name | 8:00 PM Title | 8:30 PM Title | ...
        segs=[]
        for st,en,title in blocks[:4]:
            segs.append(f"{st.strftime('%-I:%M %p')}  {title[:36]}")
        while len(segs)<4:
            segs.append("")
        row = f"[{int(num):3d}] 📺 {name[:32]:32s} | {segs[0]:44s} | {segs[1]:44s} | {segs[2]:44s} | {segs[3]:44s}"
        qg.write(row.rstrip()+"\n")
PY
}

#########################################
# EPG helpers for watching screen
#########################################
epg4_for_num() {
  local num="$1"
  [ -f "$EPG4_CACHE" ] || return
  awk -F'\t' -v n="$num" '$1==n{print;exit}' "$EPG4_CACHE" 2>/dev/null || true
}

#########################################
# DVR: LIVE (PID based)
#########################################
recording_active() {
  [ -f "$REC_PIDFILE" ] || return 1
  local pid
  pid=$(cat "$REC_PIDFILE" 2>/dev/null || echo "")
  [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null
}

start_recording_live() {
  local url="$1" chan="$2" tag="$3"
  local chsafe showsafe day ts dir outfile
  chsafe=$(echo "$chan" | tr ' /' '__' | tr -cd 'A-Za-z0-9_.-')
  [ -z "$chsafe" ] && chsafe="Channel"
  showsafe=$(echo "$tag" | tr ' /' '__' | tr -cd 'A-Za-z0-9_.-')
  day=$(date +"%Y-%m-%d")
  ts=$(date +"%Y-%m-%d_%H-%M-%S")
  dir="$RECDIR/$chsafe/$day"
  mkdir -p "$dir"
  if [ -n "${showsafe:-}" ]; then
    outfile="$dir/${chsafe}_${showsafe}_$ts.ts"
  else
    outfile="$dir/${chsafe}_$ts.ts"
  fi

  (
    ffmpeg -nostdin -y -i "$url" -c copy "$outfile" >/dev/null 2>&1
    rm -f "$REC_PIDFILE"
  ) &
  echo $! > "$REC_PIDFILE"
}

stop_recording_live() {
  local pid
  pid=$(cat "$REC_PIDFILE" 2>/dev/null || echo "")
  if [ -n "${pid:-}" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$REC_PIDFILE"
}

#########################################
# SCHEDULED BLOCK (single episode) (+30s)
#########################################
active_bg_recordings() {
  local live=""
  [ -f "$REC_PIDFILE" ] && live=$(cat "$REC_PIDFILE" 2>/dev/null || echo "")
  ps ax -o pid= -o args= 2>/dev/null | awk -v live="$live" -v rec="$RECDIR" '
    index($0,"ffmpeg") && index($0,rec) {
      if ($1 != live) count++
    }
    END{print count+0}'
}

MAX_BG_RECORDINGS=3
detect_storage_tier() {
  local dev base rota
  dev=$(df --output=source "$TV_DIR" 2>/dev/null | tail -n1 || true)
  [ -z "${dev:-}" ] && { MAX_BG_RECORDINGS=3; return; }
  base="${dev%%[0-9p]*}"
  rota=$(lsblk -ndo ROTA "$base" 2>/dev/null | head -n1 || true)
  case "${rota:-}" in
    0) MAX_BG_RECORDINGS=6 ;;
    1) MAX_BG_RECORDINGS=3 ;;
    *) MAX_BG_RECORDINGS=3 ;;
  esac
}

schedule_record_block() {
  local url="$1" chan="$2" show="$3" start_ts="$4" end_ts="$5" label="$6" pad_end="${7:-0}"

  local now_ts duration delay
  now_ts=$(date +%s)
  end_ts=$((end_ts + pad_end))
  duration=$((end_ts - start_ts))
  [ "$duration" -le 0 ] && return 0
  delay=$((start_ts - now_ts))
  if [ "$delay" -lt 0 ]; then
    delay=0
    duration=$((end_ts - now_ts))
    [ "$duration" -le 0 ] && return 0
  fi

  local chsafe showsafe day ts dir outfile
  chsafe=$(echo "$chan" | tr ' /' '__' | tr -cd 'A-Za-z0-9_.-')
  [ -z "$chsafe" ] && chsafe="Channel"
  showsafe=$(echo "$show" | tr ' /' '__' | tr -cd 'A-Za-z0-9_.-')
  day=$(date -d "@$start_ts" +"%Y-%m-%d" 2>/dev/null || date +"%Y-%m-%d")
  ts=$(date -d "@$start_ts" +"%Y-%m-%d_%H-%M-%S" 2>/dev/null || date +"%Y-%m-%d_%H-%M-%S")
  dir="$RECDIR/$chsafe/$day"
  mkdir -p "$dir"
  if [ -n "${showsafe:-}" ]; then
    outfile="$dir/${chsafe}_${showsafe}_$ts.ts"
  else
    outfile="$dir/${chsafe}_$ts.ts"
  fi

  if [ -f "$outfile" ]; then
    return 0
  fi

  local current
  current=$(active_bg_recordings)
  if [ "$current" -ge "$MAX_BG_RECORDINGS" ]; then
    return 0
  fi

  nohup bash -c "
    sleep $delay
    ffmpeg -nostdin -y -i \"$url\" -t $duration -c copy \"$outfile\" >/dev/null 2>&1
  " >/dev/null 2>&1 &
}

#########################################
# SERIES TIMERS (channel + title)
#########################################
add_series_timer() {
  local num="$1" title="$2"
  [ -z "${num:-}" ] && return
  [ -z "${title:-}" ] && return
  mkdir -p "$TV_DIR"
  local norm
  norm=$(printf '%s\n' "$title" | sed 's/^ *//;s/ *$//')
  if [ -f "$TIMERS_DB" ] && awk -F'\t' -v n="$num" -v t="$(printf '%s\n' "$norm" | tr 'A-Z' 'a-z')" '
    { if (NF>=2 && $1==n && tolower($2)==t) found=1 }
    END{exit !found}
  ' "$TIMERS_DB"; then
    return
  fi
  printf "%s\t%s\n" "$num" "$norm" >> "$TIMERS_DB"
}

#########################################
# CURRENT PROGRAM (for r-dialog “this episode” + “series”)
#########################################
current_program_for_channel() {
  # prints: start_ts \t end_ts \t label \t title
  local epg="$1" chan_name="$2"
  python3 - "$epg" "$chan_name" << 'PY'
import sys, re
from datetime import datetime
import xml.etree.ElementTree as ET

epg_path, chan_name = sys.argv[1], sys.argv[2]
tree=ET.parse(epg_path); root=tree.getroot()

def canon(s:str)->str:
  s=s or ""
  s=re.sub(r"\[[^\]]*\]"," ",s)
  s=re.sub(r"\([^)]*\)"," ",s)
  s=re.sub(r"[-–_|]"," ",s)
  s=re.sub(r"\s+"," ",s).strip().lower()
  return s

def parse_dt(s):
  if not s: return None
  for fmt in ("%Y%m%d%H%M%S %z","%Y%m%d%H%M%S%z"):
    try: return datetime.strptime(s,fmt).astimezone()
    except: pass
  return None

# find channel id
cid=None
for ch in root.findall("channel"):
  names=[dn.text.strip() for dn in ch.findall("display-name") if dn.text]
  if any(n==chan_name for n in names):
    cid=ch.get("id"); break

if not cid:
  want=canon(chan_name)
  for ch in root.findall("channel"):
    names=[dn.text.strip() for dn in ch.findall("display-name") if dn.text]
    if want and want in canon(" ".join(names)):
      cid=ch.get("id"); break

if not cid:
  sys.exit(0)

now=datetime.now().astimezone()

best=None
for p in root.findall("programme"):
  if p.get("channel")!=cid: continue
  st=parse_dt(p.get("start")); en=parse_dt(p.get("stop"))
  if not st or not en: continue
  if st <= now < en:
    t_el=p.find("title")
    title=(t_el.text.strip() if (t_el is not None and t_el.text) else "")
    if not title: continue
    label=f"{st.strftime('%-I:%M %p')}–{en.strftime('%-I:%M %p')}"
    best=(int(st.timestamp()), int(en.timestamp()), label, title)
    break

if best:
  print(f"{best[0]}\t{best[1]}\t{best[2]}\t{best[3]}")
PY
}

#########################################
# WATCH SCREEN (buffering UI + 4 blocks as 12h local time)
#########################################
watch_screen_header() {
  local num="$1" name="$2"
  clear
  echo "╔════════════════════════════════════════╗"
  printf "║ 📺  TV ▸ TVpass ▸ Watching  %-10s ║\n" "$(clock12)"
  echo "╚════════════════════════════════════════╝"
  echo -e "  \e[96m▶ Channel $num: $name\e[0m"
  echo
}

watch_screen_blocks() {
  local num="$1"
  local line t1 s1 t2 s2 t3 s3 t4 s4
  line="$(epg4_for_num "$num" || true)"
  if [ -n "${line:-}" ]; then
    IFS=$'\t' read -r _ t1 s1 t2 s2 t3 s3 t4 s4 <<< "$line"
    # Display as time-based blocks (12-hour local time), not NEXT/LATER
    [ -n "${t1:-}" ] && echo "  🧱 ${t1}  ${s1}"
    [ -n "${t2:-}" ] && echo "  🧱 ${t2}  ${s2}"
    [ -n "${t3:-}" ] && echo "  🧱 ${t3}  ${s3}"
    [ -n "${t4:-}" ] && echo "  🧱 ${t4}  ${s4}"
    echo
  fi
}

#########################################
# RECORD DIALOG (LOCKED CHANGE #4)
#########################################
record_dialog_while_watching() {
  local num="$1" name="$2" url="$3"
  local cur
  cur="$(current_program_for_channel "$EPG" "$name" || true)"

  local st="" en="" label="" title=""
  if [ -n "${cur:-}" ]; then
    IFS=$'\t' read -r st en label title <<< "$cur"
  fi

  local choices=()
  if recording_active; then
    choices+=("🛑 Stop LIVE recording")
  else
    choices+=("🔴 Record LIVE feed (toggle)")
  fi
  if [ -n "${title:-}" ]; then
    choices+=("🧠 Record SERIES: $title")
    choices+=("🎬 Record THIS episode (+30s): $label  $title")
  else
    choices+=("🧠 Record SERIES (current show) — (EPG not found)")
    choices+=("🎬 Record THIS episode (+30s) — (EPG not found)")
  fi
  choices+=("⬅ Back")

  local pick
  pick="$(printf '%s\n' "${choices[@]}" | fzf --ansi --prompt="🎥 Recording ($(clock12)) > " --header="Pick one" )" || true
  [ -z "${pick:-}" ] && return 0
  echo "$pick" | grep -q "⬅ Back" && return 0

  case "$pick" in
    *"Stop LIVE"*)
      stop_recording_live
      ;;
    *"Record LIVE"*)
      start_recording_live "$url" "$name" "$(date +%H%M)"
      ;;
    *"Record SERIES"*)
      [ -n "${title:-}" ] && add_series_timer "$num" "$title"
      ;;
    *"Record THIS episode"*)
      if [ -n "${st:-}" ] && [ -n "${en:-}" ] && [ -n "${title:-}" ]; then
        schedule_record_block "$url" "$name" "$title" "$st" "$en" "$label" 30
      fi
      ;;
  esac
}

#########################################
# PLAY (TVPASS) — mpv spam hidden
#########################################
play_channel() {
  local CUR="$1" TABLE="$2"
  local LAST NAME URL code

  LAST=$(awk -F'\t' 'END{print $1}' "$TABLE")

  while true; do
    NAME=$(awk -F'\t' -v i="$CUR" '$1==i{print $2}' "$TABLE")
    URL=$(awk -F'\t' -v i="$CUR" '$1==i{print $3}' "$TABLE")

    watch_screen_header "$CUR" "$NAME"
    watch_screen_blocks "$CUR"

    if recording_active; then
      echo "  🔴 LIVE RECORDING ACTIVE"
      echo
    fi

    echo "  ⬆ Channel Up (Ctrl+Up)    ⬇ Channel Down (Ctrl+Down)"
    echo "  🎥 Record (r)             ❌ Cancel Watch (q/Esc)"
    echo

    [ -z "${URL:-}" ] && { read -rp "No URL. ENTER..." _; break; }

    # mpv: hide spam
    mpv --fullscreen --really-quiet --no-terminal --input-conf="$INPUT_CONF" "$URL" 2>/dev/null || true
    code=$?

    case "$code" in
      3) CUR=$((CUR+1)); [ "$CUR" -gt "$LAST" ] && CUR=1 ;;
      4) CUR=$((CUR-1)); [ "$CUR" -lt 1 ] && CUR="$LAST" ;;
      5) record_dialog_while_watching "$CUR" "$NAME" "$URL" ;;   # LOCKED CHANGE #4
      *) break ;;
    esac
  done
}

#########################################
# GUIDE24 MAP (per-channel day lineup)
#########################################
build_channel_24h_map() {
  local chan_name="$1"
  : > "$GUIDE24_MAP"
  python3 - "$EPG" "$chan_name" "$GUIDE24_MAP" << 'PY'
import sys, re
from datetime import datetime, timedelta
import xml.etree.ElementTree as ET

epg_path, chan_name, out_path = sys.argv[1:]
tree=ET.parse(epg_path); root=tree.getroot()

def canon(s:str)->str:
  s=s or ""
  s=re.sub(r"\[[^\]]*\]"," ",s)
  s=re.sub(r"\([^)]*\)"," ",s)
  s=re.sub(r"[-–_|]"," ",s)
  s=re.sub(r"\s+"," ",s).strip().lower()
  return s

def parse_dt(s):
  if not s: return None
  for fmt in ("%Y%m%d%H%M%S %z","%Y%m%d%H%M%S%z"):
    try: return datetime.strptime(s,fmt).astimezone()
    except: pass
  return None

cid=None
for ch in root.findall("channel"):
  names=[dn.text.strip() for dn in ch.findall("display-name") if dn.text]
  if any(n==chan_name for n in names):
    cid=ch.get("id"); break
if not cid:
  want=canon(chan_name)
  for ch in root.findall("channel"):
    names=[dn.text.strip() for dn in ch.findall("display-name") if dn.text]
    if want and want in canon(" ".join(names)):
      cid=ch.get("id"); break
if not cid:
  open(out_path,"w").close()
  sys.exit(0)

now=datetime.now().astimezone()
start=now.replace(hour=0,minute=0,second=0,microsecond=0)
end=start+timedelta(days=1)

rows=[]
for p in root.findall("programme"):
  if p.get("channel")!=cid: continue
  st=parse_dt(p.get("start")); en=parse_dt(p.get("stop"))
  if not st or not en: continue
  if en<=start or st>=end: continue
  t_el=p.find("title")
  title=(t_el.text.strip() if (t_el is not None and t_el.text) else "")
  if not title: continue
  stc=max(st,start); enc=min(en,end)
  label=f"{stc.strftime('%-I:%M %p')}–{enc.strftime('%-I:%M %p')}"
  rows.append((int(stc.timestamp()), int(enc.timestamp()), label, title))

rows.sort(key=lambda r:r[0])

with open(out_path,"w",encoding="utf-8") as f:
  for st,en,label,title in rows:
    f.write(f"{st}\t{en}\t{label}\t{title}\n")
PY
}

#########################################
# TVPASS CHANNEL LIST (with Back row)
#########################################
print_tvpass_channel_rows() {
  local TABLE="$1"
  awk -F'\t' '
    { if($1!="") printf "[%3s] 📺 %s\n", $1, $2 }
  ' "$TABLE"
  echo "[---] ⬅ Back"
}

choose_tvpass_channel() {
  local TABLE="$1"
  local choice
  choice="$(
    print_tvpass_channel_rows "$TABLE" |
    fzf --ansi --prompt="TV ▸ TVpass ▸ Channels ($(clock12)) > " --header="Arrows/Mouse + ENTER • ESC/Back returns"
  )" || true
  [ -z "${choice:-}" ] && return 1
  echo "$choice" | grep -q "⬅ Back" && return 1
  echo "$choice" | sed 's/^\[\s*\([0-9]\+\)\].*/\1/' 2>/dev/null
}

#########################################
# QUICK GUIDE (NOW + 3 blocks, restored vibe)
# - pick channel row -> choose NOW (play) or pick a future block -> record single/series
#########################################
quick_guide() {
  [ -s "$QGUIDE_CACHE" ] || { echo "Quick Guide missing."; read -rp "ENTER..." _; return; }

  local row
  row="$(
    (cat "$QGUIDE_CACHE"; echo "[---] ⬅ Back") |
    fzf --ansi --prompt="TV ▸ Quick Guide ($(clock12)) > " --header="Pick a channel row"
  )" || true
  [ -z "${row:-}" ] && return
  echo "$row" | grep -q "⬅ Back" && return

  local num
  num="$(echo "$row" | sed 's/^\[\s*\([0-9]\+\)\].*/\1/' 2>/dev/null || true)"
  [ -z "${num:-}" ] && return

  local name url
  name="$(awk -F'\t' -v i="$num" '$1==i{print $2}' "$TABLE")"
  url="$(awk -F'\t' -v i="$num" '$1==i{print $3}' "$TABLE")"

  # Build 4 blocks for that channel from EPG4 cache (time+title)
  local line t1 s1 t2 s2 t3 s3 t4 s4
  line="$(epg4_for_num "$num" || true)"
  [ -z "${line:-}" ] && { play_channel "$num" "$TABLE"; return; }
  IFS=$'\t' read -r _ t1 s1 t2 s2 t3 s3 t4 s4 <<< "$line"

  local pick
  pick="$(
    printf "%s\n" \
      "▶ NOW  (${t1})  ${s1}" \
      "🧱 ${t2}  ${s2}" \
      "🧱 ${t3}  ${s3}" \
      "🧱 ${t4}  ${s4}" \
      "⬅ Back" |
    fzf --ansi --prompt="Quick Guide ▸ $num ($(clock12)) > " --header="NOW plays • future blocks record"
  )" || true
  [ -z "${pick:-}" ] && return
  echo "$pick" | grep -q "⬅ Back" && return

  if echo "$pick" | grep -q "^▶ NOW"; then
    play_channel "$num" "$TABLE"
    return
  fi

  # Future block clicked -> record single/series (LOCKED RULE)
  build_channel_24h_map "$name"
  [ ! -s "$GUIDE24_MAP" ] && return

  # find matching title text from pick (after time)
  local chosen_title
  chosen_title="$(echo "$pick" | sed 's/^🧱 *[^ ]* [AP]M  *//' || true)"

  # locate first occurrence in day map with that title
  local row2 st en label title
  row2="$(awk -F'\t' -v t="$chosen_title" '$4==t{print; exit}' "$GUIDE24_MAP" || true)"
  [ -z "${row2:-}" ] && return
  IFS=$'\t' read -r st en label title <<< "$row2"

  local action
  action="$(
    printf "%s\n" \
      "🎬 Record SINGLE episode (+30s auto end)" \
      "🧠 Record SERIES (every matching title on this channel)" \
      "⬅ Back" |
    fzf --ansi --prompt="Record ▸ $num ($(clock12)) > " --header="$label  $title"
  )" || true
  [ -z "${action:-}" ] && return
  echo "$action" | grep -q "⬅ Back" && return

  case "$action" in
    *SINGLE*) schedule_record_block "$url" "$name" "$title" "$st" "$en" "$label" 30 ;;
    *SERIES*) add_series_timer "$num" "$title" ;;
  esac
}

#########################################
# 24 HOUR GUIDE (channel list -> day lineup -> info -> record single/series)
#########################################
guide24() {
  local num
  num="$(choose_tvpass_channel "$TABLE" || true)"
  [ -z "${num:-}" ] && return

  local name url
  name="$(awk -F'\t' -v i="$num" '$1==i{print $2}' "$TABLE")"
  url="$(awk -F'\t' -v i="$num" '$1==i{print $3}' "$TABLE")"

  build_channel_24h_map "$name"
  [ ! -s "$GUIDE24_MAP" ] && { echo "No guide for $name"; read -rp "ENTER..." _; return; }

  local pick
  pick="$(
    (awk -F'\t' '{printf "🧱 %s  %s\n", $3, $4}' "$GUIDE24_MAP"; echo "⬅ Back") |
    fzf --ansi --prompt="TV ▸ 24 Hour Guide ▸ $num ($(clock12)) > " --header="Pick a time block"
  )" || true
  [ -z "${pick:-}" ] && return
  echo "$pick" | grep -q "⬅ Back" && return

  local label title
  label="$(echo "$pick" | sed 's/^🧱 *\([^ ]* [AP]M–[^ ]* [AP]M\).*/\1/' || true)"
  title="$(echo "$pick" | sed 's/^🧱 *[^ ]* [AP]M–[^ ]* [AP]M  //' || true)"

  local row st en
  row="$(awk -F'\t' -v l="$label" -v t="$title" '$3==l && $4==t{print; exit}' "$GUIDE24_MAP" || true)"
  [ -z "${row:-}" ] && return
  IFS=$'\t' read -r st en _l _t <<< "$row"

  local action
  action="$(
    printf "%s\n" \
      "🎬 Record SINGLE episode (+30s auto end)" \
      "🧠 Record SERIES (every matching title on this channel)" \
      "⬅ Back" |
    fzf --ansi --prompt="Info ▸ $num ($(clock12)) > " --header="$label  $title"
  )" || true
  [ -z "${action:-}" ] && return
  echo "$action" | grep -q "⬅ Back" && return

  case "$action" in
    *SINGLE*) schedule_record_block "$url" "$name" "$title" "$st" "$en" "$label" 30 ;;
    *SERIES*) add_series_timer "$num" "$title" ;;
  esac
}

#########################################
# RECORDINGS OPEN
#########################################
open_recordings() {
  mkdir -p "$RECDIR"
  if command -v thunar >/dev/null 2>&1; then
    thunar "$RECDIR" >/dev/null 2>&1 &
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$RECDIR" >/dev/null 2>&1 &
  fi
  read -rp "ENTER..." _
}

#########################################
# TIMERS LIST / SCAN (kept)
#########################################
timers_list() {
  clear
  echo "╔════════════════════════════════════════╗"
  printf "║ ⏱  TV ▸ Timers ▸ List     %-10s ║\n" "$(clock12)"
  echo "╚════════════════════════════════════════╝"
  echo
  if [ ! -s "$TIMERS_DB" ]; then
    echo "No series timers."
    echo
    read -rp "ENTER..." _
    return
  fi
  nl -ba "$TIMERS_DB" | sed 's/\t/  →  /'
  echo
  read -rp "ENTER..." _
}

timers_scan() {
  clear
  echo "╔════════════════════════════════════════╗"
  printf "║ 🔁  TV ▸ Timers ▸ Scan EPG  %-10s ║\n" "$(clock12)"
  echo "╚════════════════════════════════════════╝"
  echo
  [ ! -s "$TIMERS_DB" ] && { echo "No timers to scan."; echo; read -rp "ENTER..." _; return; }

  local TMP
  TMP="$(mktemp)"

  python3 - "$EPG" "$TIMERS_DB" "$TABLE" > "$TMP" << 'PY'
import sys, re
from datetime import datetime, timedelta
import xml.etree.ElementTree as ET

epg_path, timers_path, table_path = sys.argv[1:]
tree=ET.parse(epg_path); root=tree.getroot()

def canon_name(s: str) -> str:
    s = s or ""
    s = re.sub(r"\[[^\]]*\]", " ", s)
    s = re.sub(r"\([^)]*\)", " ", s)
    s = re.sub(r"[-–_|]", " ", s)
    for token in ["HD","East","West","US","USA","Feed","TV","Channel","Network","Latino"]:
        s = re.sub(r"\b"+re.escape(token)+r"\b"," ",s,flags=re.I)
    s = re.sub(r"\s+"," ",s).strip().lower()
    return s

channels=[]
for ch in root.findall("channel"):
    cid=ch.get("id","")
    names=[dn.text.strip() for dn in ch.findall("display-name") if dn.text]
    channels.append((cid,names))

def find_channel_id(name):
    name=(name or "").strip()
    if not name: return None
    for cid,names in channels:
        for dn in names:
            if dn == name:
                return cid
    short=canon_name(name)
    if not short: return None
    for cid,names in channels:
        joined=" ".join(n for n in names if n)
        if short and short in canon_name(joined):
            return cid
    return None

progs_by_id={}
for p in root.findall("programme"):
    cid=p.get("channel")
    if not cid: continue
    progs_by_id.setdefault(cid,[]).append(p)

def parse_dt(s):
    if not s: return None
    for fmt in ("%Y%m%d%H%M%S %z","%Y%m%d%H%M%S%z"):
        try: return datetime.strptime(s,fmt).astimezone()
        except: pass
    return None

num_to_name={}
with open(table_path,"r",encoding="utf-8") as tf:
    for line in tf:
        parts=line.rstrip("\n").split("\t")
        if len(parts)<2: continue
        num_to_name[parts[0]]=parts[1]

now=datetime.now().astimezone()
horizon=now+timedelta(days=2)

def human(st,en):
    return f"{st.strftime('%-I:%M %p')}–{en.strftime('%-I:%M %p')}"

with open(timers_path,"r",encoding="utf-8") as tf:
    for line in tf:
        line=line.strip()
        if not line: continue
        num,title=line.split("\t",1)
        title=title.strip()
        chan_name=num_to_name.get(num)
        if not chan_name: continue
        cid=find_channel_id(chan_name)
        if not cid: continue
        wanted=title.lower()
        for p in progs_by_id.get(cid,[]):
            st=parse_dt(p.get("start")); en=parse_dt(p.get("stop"))
            if not st or not en: continue
            if en<=now or st>=horizon: continue
            t_el=p.find("title")
            ttxt=(t_el.text.strip() if (t_el is not None and t_el.text) else "")
            if not ttxt: continue
            if ttxt.strip().lower()!=wanted: continue
            print(f"{num}\t{int(st.timestamp())}\t{int(en.timestamp())}\t{ttxt}\t{human(st,en)}")
PY

  if [ ! -s "$TMP" ]; then
    echo "No upcoming episodes found."
    rm -f "$TMP"
    echo
    read -rp "ENTER..." _
    return
  fi

  echo ">>> Scheduling upcoming episodes..."
  while IFS=$'\t' read -r NUM ST EN TITLE LABEL; do
    [ -z "${NUM:-}" ] && continue
    local NAME URL
    NAME="$(awk -F'\t' -v i="$NUM" '$1==i{print $2}' "$TABLE")"
    URL="$(awk -F'\t' -v i="$NUM" '$1==i{print $3}' "$TABLE")"
    [ -z "${URL:-}" ] && continue
    schedule_record_block "$URL" "$NAME" "$TITLE" "$ST" "$EN" "$LABEL" 0
  done < "$TMP"

  rm -f "$TMP"
  echo
  read -rp "ENTER..." _
}

#########################################
# GLOBAL (simple: keep core)
#########################################
iptv_ensure_playlist() {
  local file="$1" url="$2"
  [ -s "$file" ] && return 0
  curl -sS -L "$url" -o "$file"
}

iptv_build_tmp_from_playlist() {
  local src="$1" tmp="$2"
  awk -v OFS='\t' '
    BEGIN{name=""}
    /^#EXTINF/{
      name=$0
      sub(/.*,/,"",name)
      next
    }
    /^https?:\/\//{
      if (name=="") name="Unknown"
      print name,$0
      name=""
    }
  ' "$src" > "$tmp"
}

global_search() {
  iptv_ensure_playlist "$GLOBAL_INDEX" "$GLOBAL_INDEX_URL" || true
  local TMP S_TMP
  TMP="$(mktemp)"
  iptv_build_tmp_from_playlist "$GLOBAL_INDEX" "$TMP"

  clear
  echo "╔════════════════════════════════════════╗"
  printf "║ 🔍  TV ▸ Global ▸ Search   %-10s ║\n" "$(clock12)"
  echo "╚════════════════════════════════════════╝"
  read -rp "Search term: " Q
  [ -z "${Q:-}" ] && { rm -f "$TMP"; return; }

  S_TMP="$(mktemp)"
  while IFS=$'\t' read -r name url; do
    printf '%s\n' "$name" | grep -iF -- "$Q" >/dev/null 2>&1 && printf "%s\t%s\n" "$name" "$url" >> "$S_TMP"
  done < "$TMP"

  if [ ! -s "$S_TMP" ]; then
    echo "No matches."
    rm -f "$TMP" "$S_TMP"
    read -rp "ENTER..." _
    return
  fi

  local pick idx
  pick="$(
    (awk -F'\t' '{printf "[%4d] 🌍 %s\n", NR, $1}' "$S_TMP"; echo "[----] ⬅ Back") |
    fzf --ansi --prompt="TV ▸ Global Search ($(clock12)) > "
  )" || true
  [ -z "${pick:-}" ] && { rm -f "$TMP" "$S_TMP"; return; }
  echo "$pick" | grep -q "⬅ Back" && { rm -f "$TMP" "$S_TMP"; return; }
  idx="$(echo "$pick" | sed 's/^\[\s*\([0-9]\+\)\].*/\1/' || true)"
  [ -z "${idx:-}" ] && { rm -f "$TMP" "$S_TMP"; return; }

  local NAME URL
  NAME="$(awk -F'\t' -v i="$idx" 'NR==i{print $1}' "$S_TMP")"
  URL="$(awk -F'\t' -v i="$idx" 'NR==i{print $2}' "$S_TMP")"

  mpv --fullscreen --really-quiet --no-terminal --input-conf="$INPUT_CONF" "$URL" 2>/dev/null || true

  rm -f "$TMP" "$S_TMP"
}

#########################################
# MAIN MENU (restored options)
#########################################
main_menu() {
  while true; do
    local pick
    pick="$(
      printf "%s\n" \
        "📺 TVpass Channels" \
        "🗓️ Quick Guide (NOW + 3 blocks)" \
        "📆 24 Hour Guide (record blocks)" \
        "🌍 Global Search" \
        "📂 Recordings" \
        "⏱ Timers (list)" \
        "🔁 Timers (scan EPG)" \
        "⟳ Update TVpass" \
        "❌ Quit" |
      fzf --ansi --prompt="TV ▸ Main ($(clock12)) > " --header="Arrows/Mouse + ENTER"
    )" || true
    [ -z "${pick:-}" ] && break

    case "$pick" in
      "📺 TVpass Channels")
        local sel
        sel="$(choose_tvpass_channel "$TABLE" || true)"
        [ -n "${sel:-}" ] && play_channel "$sel" "$TABLE"
        ;;
      "🗓️ Quick Guide (NOW + 3 blocks)")
        quick_guide
        ;;
      "📆 24 Hour Guide (record blocks)")
        guide24
        ;;
      "🌍 Global Search")
        global_search
        ;;
      "📂 Recordings")
        open_recordings
        ;;
      "⏱ Timers (list)")
        timers_list
        ;;
      "🔁 Timers (scan EPG)")
        timers_scan
        ;;
      "⟳ Update TVpass")
        tvpass_update_all
        ;;
      "❌ Quit")
        break
        ;;
    esac
  done
}

#########################################
# ENTRY
#########################################
case "${1:-}" in
  update) tvpass_update_all ;;
esac

ensure_input_conf
detect_storage_tier

tvpass_ensure_playlist
tvpass_ensure_guide

loading_screen
TABLE="$(build_table)"
build_epg_caches "$TABLE"

# prime global cache best-effort
curl -sS -L "$MAIN_URL" -o "$MAIN_PLAYLIST" >/dev/null 2>&1 || true
curl -sS -L "$GLOBAL_INDEX_URL" -o "$GLOBAL_INDEX" >/dev/null 2>&1 || true

main_menu

rm -f "$TABLE"
TVEOF

chmod +x "$HOME/.local/bin/tv"

# Desktop launcher (optional, nice)
cat > "$HOME/.local/share/applications/tv.desktop" << 'DESK'
[Desktop Entry]
Type=Application
Name=TV
Comment=TV Terminal App
Exec=gnome-terminal -- bash -lc "tv"
Terminal=false
Categories=AudioVideo;
DESK

echo "============================================"
echo " DONE. Run: tv"
echo "============================================"
EOF
