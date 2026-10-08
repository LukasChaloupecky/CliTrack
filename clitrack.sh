#!/usr/bin/env bash
# =============================================================================
# clitrack - keep track of the command-line tools installed by a user
#
# Every user gets a private list (default: ~/.local/share/clitrack/tools.tsv).
# For each tool clitrack remembers how its version is queried, where it came
# from (apt, npm, cargo, ...), when it was added, a free-text note and the last
# version it saw - so you can later spot tools that are missing or were upgraded.
#
# Install:   chmod +x clitrack.sh && mv clitrack.sh ~/.local/bin/clitrack
# Help:      clitrack --help
# Requires:  bash >= 4.4, awk, grep, sort (timeout / dpkg / rpm are optional)
# =============================================================================

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "clitrack requires bash 4.4 or newer" >&2
  exit 1
fi

set -u

readonly CLITRACK_VERSION="1.0.0"
readonly PROG="${0##*/}"
readonly DATA_DIR="${CLITRACK_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/clitrack}"
readonly DB="$DATA_DIR/tools.tsv"
readonly TAB=$'\t'

# Tools that --scan looks for in addition to the user's own bin directories.
COMMON_TOOLS=(
  git curl wget jq yq node npm npx yarn pnpm bun deno python3 pip3 pipx go
  rustc cargo java mvn gradle ruby gem php composer dotnet docker
  docker-compose podman kubectl helm terraform ansible aws gcloud az gh vim nvim
  emacs nano tmux screen htop btop ssh rsync make cmake gcc g++ clang sqlite3
  psql mysql redis-cli ffmpeg convert unzip zip tar fzf rg fd bat eza tree
  shellcheck ncdu
)

# ----------------------------------------------------------------- colours --
RED='' GRN='' YEL='' BLD='' DIM='' RST=''
ERED='' EYEL='' ERST=''
if [[ -z ${NO_COLOR:-} ]]; then
  if [[ -t 1 ]]; then
    RED=$'\e[31m' GRN=$'\e[32m' YEL=$'\e[33m' BLD=$'\e[1m' DIM=$'\e[2m' RST=$'\e[0m'
  fi
  if [[ -t 2 ]]; then
    ERED=$'\e[31m' EYEL=$'\e[33m' ERST=$'\e[0m'
  fi
fi

die()  { printf '%s%s: error:%s %s\n'   "$ERED" "$PROG" "$ERST" "$*" >&2; exit 1; }
warn() { printf '%s%s: warning:%s %s\n' "$EYEL" "$PROG" "$ERST" "$*" >&2; }
info() { printf '%s\n' "$*"; }

# ----------------------------------------------------------------- helpers --
valid_name() {
  local re='^[A-Za-z0-9][A-Za-z0-9._+@-]*$'
  [[ ${1:-} =~ $re ]]
}

clean() {  # strip tabs/newlines so a value can never break the TSV file
  local s=${1:-}
  s=${s//$'\t'/ }
  s=${s//$'\n'/ }
  printf '%s' "$s"
}

jesc() {  # minimal JSON string escaping
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

tool_path()    { type -P -- "$1" 2>/dev/null; }
is_installed() { [[ -n $(tool_path "$1") ]]; }

confirm() {  # confirm "question"  (always yes with -y, always no without a tty)
  (( OPT_YES )) && return 0
  [[ -t 0 ]] || return 1
  local ans
  read -r -p "$1 [y/N] " ans
  [[ $ans == [yY]* ]]
}

maxw() {  # longest first-column entry of the lines given on stdin
  cut -f1 | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'
}

# ----------------------------------------------------------- data file I/O --
init_db() {
  mkdir -p -- "$DATA_DIR" || die "cannot create data directory: $DATA_DIR"
  if [[ ! -f $DB ]]; then
    printf '# clitrack data file (tab separated)\n# name\tversion_cmd\torigin\tadded\tnote\tlast_version\n' \
      > "$DB" || die "cannot create $DB"
  fi
}

backup_db() { cp -- "$DB" "$DB.bak" 2>/dev/null; return 0; }

all_records() {
  grep -v -e '^#' -e '^[[:space:]]*$' -- "$DB" | sort -f -t "$TAB" -k1,1
}

has_tool() {
  awk -F'\t' -v n="$1" '$1 == n { f = 1 } END { exit !f }' "$DB"
}

make_line() {  # name cmd origin added note last   (empty values stored as "-")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "${2:--}" "${3:--}" "${4:--}" "${5:--}" "${6:--}"
}

parse_line() {  # sets R_NAME R_CMD R_ORIGIN R_ADDED R_NOTE R_LAST
  R_NAME="" R_CMD="" R_ORIGIN="" R_ADDED="" R_NOTE="" R_LAST=""
  IFS=$'\t' read -r R_NAME R_CMD R_ORIGIN R_ADDED R_NOTE R_LAST <<< "$1"
  [[ $R_CMD    == - ]] && R_CMD=""
  [[ $R_ORIGIN == - ]] && R_ORIGIN=""
  [[ $R_ADDED  == - ]] && R_ADDED=""
  [[ $R_NOTE   == - ]] && R_NOTE=""
  [[ $R_LAST   == - ]] && R_LAST=""
  return 0
}

load_record() {
  local line
  line=$(awk -F'\t' -v n="$1" '$1 == n { print; exit }' "$DB")
  [[ -n $line ]] || return 1
  parse_line "$line"
}

replace_record() {  # name newline
  local tmp
  tmp=$(mktemp "$DATA_DIR/.tmp.XXXXXX") || die "cannot create temp file in $DATA_DIR"
  NEWREC="$2" awk -F'\t' -v n="$1" \
    '$1 == n { print ENVIRON["NEWREC"]; next } { print }' "$DB" > "$tmp" \
    && mv -- "$tmp" "$DB" || { rm -f -- "$tmp"; die "could not update $DB"; }
}

delete_record() {  # name
  local tmp
  tmp=$(mktemp "$DATA_DIR/.tmp.XXXXXX") || die "cannot create temp file in $DATA_DIR"
  awk -F'\t' -v n="$1" '$1 != n' "$DB" > "$tmp" \
    && mv -- "$tmp" "$DB" || { rm -f -- "$tmp"; die "could not update $DB"; }
}

# --------------------------------------------------- version / origin lookup --
if command -v timeout >/dev/null 2>&1; then
  _run() { timeout -k 1 5 "$@"; }
else
  _run() { "$@"; }
fi

probe() {  # run a command safely: no stdin, 5 s limit, stderr merged, 5 lines max
  ( cd / 2>/dev/null; _run "$@" </dev/null 2>&1 | head -n 5 )
}

extract_version() {
  grep -oE '[0-9]+(\.[0-9]+)+([-+~][0-9A-Za-z.]+)*' | head -n 1
}

normalize_cmd() {  # name cmd -> full command ("-v" becomes "npm -v")
  local name=$1 cmd first
  cmd=$(clean "${2:-}")
  [[ -n $cmd ]] || return 0
  first=${cmd%% *}
  if [[ ${first##*/} == "$name" ]]; then
    printf '%s' "$cmd"
  else
    printf '%s %s' "$name" "$cmd"
  fi
}

detect_version() {  # name [full command]  -> prints version or nothing
  local name=$1 cmd=${2:-} out ver="" flag
  if [[ -n $cmd ]]; then
    out=$(probe bash -c "$cmd")
    ver=$(extract_version <<< "$out")
  else
    for flag in --version -V -version version -v; do
      out=$(probe "$name" "$flag")
      ver=$(extract_version <<< "$out")
      [[ -n $ver ]] && break
    done
  fi
  printf '%s' "$ver"
}

classify_path() {
  case $1 in
    */node_modules/*)                     echo npm ;;
    */.nvm/*)                             echo nvm ;;
    */.cargo/bin/*)                       echo cargo ;;
    */go/bin/*)                           echo go ;;
    */.bun/*)                             echo bun ;;
    */.deno/*)                            echo deno ;;
    */pipx/*)                             echo pipx ;;
    */.pyenv/*|*/site-packages/*)         echo pip ;;
    /snap/*|/var/lib/snapd/*)             echo snap ;;
    */linuxbrew/*|*/.linuxbrew/*)         echo brew ;;
    /usr/local/*)                         echo manual ;;
  esac
}

pkg_owner() {  # which system package manager owns this file?
  case $1 in
    /usr/*|/bin/*|/sbin/*|/lib*|/etc/*) ;;
    *) return 0 ;;
  esac
  if   command -v dpkg   >/dev/null 2>&1 && dpkg -S "$1"   >/dev/null 2>&1; then echo apt
  elif command -v rpm    >/dev/null 2>&1 && rpm -qf "$1"   >/dev/null 2>&1; then echo rpm
  elif command -v pacman >/dev/null 2>&1 && pacman -Qo "$1" >/dev/null 2>&1; then echo pacman
  fi
}

detect_source() {  # best-effort guess of where a tool came from
  local p r s
  p=$(tool_path "$1")
  [[ -n $p ]] || { echo unknown; return 0; }
  r=$(readlink -f -- "$p" 2>/dev/null) || r=$p
  r=${r:-$p}
  s=$(classify_path "$r")
  [[ -n $s ]] || s=$(classify_path "$p")
  [[ -n $s ]] || s=$(pkg_owner "$r")
  if [[ -z $s ]]; then
    case $p in
      "$HOME"/*) s=user ;;
      /opt/*)    s=opt ;;
      *)         s=system ;;
    esac
  fi
  echo "$s"
}

# ------------------------------------------------------------------ actions --
usage() {
  cat <<EOF
$PROG $CLITRACK_VERSION - keep track of the command-line tools you have installed

USAGE
  $PROG ACTION [TOOL...] [MODIFIERS]

ACTIONS
  -a, --add TOOL...          Add tools to the list
  -r, --remove TOOL...       Remove tools from the list
  -e, --edit TOOL            Change command / note / origin of a tracked tool
  -l, --list                 List tracked tools: status, version, origin, ...
  -v, --tool-version TOOL... Show the installed version of a tool
                             (works for untracked tools too, e.g. "$PROG -v npm")
  -i, --info TOOL...         Show everything known about a tool
  -k, --check                Check all tools: still installed? version changed?
  -s, --sync [TOOL...]       Refresh the recorded versions (all tools if none given)
  -f, --find TERM            Search tool name, origin and note
  -S, --scan                 Discover installed tools and offer to add them
  -x, --export [FILE]        Export the list (to stdout if no FILE)
  -I, --import FILE          Import tools from an export file (existing ones are kept)
      --count                Print the number of tracked tools
      --path                 Print the location of the data file
      --clear                Remove ALL tools from the list
  -V, --version              Show the version of $PROG itself
  -h, --help                 Show this help

MODIFIERS
  -c, --cmd CMD              Version command, e.g. -c "npm -v" or just -c "-v"
                             (default: auto-detect via --version, -V, version, ...)
  -n, --note TEXT            Free-text note for -a / -e
  -o, --origin SRC           Where it came from (apt, npm, pip, cargo, manual ...)
                             Used by -a / -e, and as a filter for -l / -f
  -j, --json                 JSON output for -l
  -F, --fast                 -l: do not run the tools, show recorded versions
  -q, --quiet                -v: print only the version number
  -y, --yes                  Do not ask for confirmation
  Short flags can be combined:  $PROG -lj   $PROG -ac "-v" -n "my note" mytool

EXAMPLES
  $PROG -a git curl jq                   add three tools
  $PROG -a npm -c "npm -v" -n "Node package manager"
  $PROG -a mytool -c -version -o manual  custom version flag and origin
  $PROG -l                               list everything
  $PROG -l -o npm                        only tools that came from npm
  $PROG -lj                              list as JSON
  $PROG -v npm                           version of npm  ->  npm 10.2.4
  $PROG -v node -q                       only the number ->  20.11.0
  $PROG -r jq                            remove jq
  $PROG -k                               report missing / upgraded tools
  $PROG -s                               remember the current versions
  $PROG -S                               find installed tools and add them
  $PROG -x backup.tsv; $PROG -I backup.tsv

FILES / ENVIRONMENT
  Data file:    $DB
  CLITRACK_DIR  override the data directory
  NO_COLOR      disable colours
EOF
}

add_one() {  # name cmd origin note
  local name=$1 cmd=$2 src=$3 note=$4 ver=""
  if ! valid_name "$name"; then
    warn "invalid tool name: '$name'"
    return 1
  fi
  if has_tool "$name"; then
    warn "$name is already tracked (change it with: $PROG -e $name ...)"
    return 1
  fi
  cmd=$(normalize_cmd "$name" "$cmd")
  note=$(clean "$note")
  src=$(clean "$src")
  [[ -n $src ]] || src=$(detect_source "$name")
  if is_installed "$name"; then
    ver=$(detect_version "$name" "$cmd")
  else
    warn "$name was not found in PATH - tracking it anyway"
    src=${src/#unknown/}
  fi
  make_line "$name" "$cmd" "$src" "$(date +%F)" "$note" "$ver" >> "$DB"
  printf '%s[+]%s added %s%s\n' "$GRN" "$RST" "$name" "${ver:+  ($ver)}"
}

cmd_add() {
  (( $# )) || die "--add needs at least one tool name (e.g. $PROG -a git)"
  local rc=0 name
  for name in "$@"; do
    add_one "$name" "$OPT_CMD" "$OPT_ORIGIN" "$OPT_NOTE" || rc=1
  done
  return $rc
}

cmd_remove() {
  (( $# )) || die "--remove needs at least one tool name"
  local rc=0 name
  backup_db
  for name in "$@"; do
    if has_tool "$name"; then
      delete_record "$name"
      printf '%s[-]%s removed %s\n' "$RED" "$RST" "$name"
    else
      warn "$name is not tracked"
      rc=1
    fi
  done
  return $rc
}

cmd_edit() {
  (( $# == 1 )) || die "--edit takes exactly one tool name"
  local name=$1
  load_record "$name" || die "$name is not tracked (add it with: $PROG -a $name)"
  (( SET_CMD || SET_NOTE || SET_ORIGIN )) || die "nothing to change - use -c, -n and/or -o"
  (( SET_CMD ))    && R_CMD=$(normalize_cmd "$name" "$OPT_CMD")
  (( SET_NOTE ))   && R_NOTE=$(clean "$OPT_NOTE")
  (( SET_ORIGIN )) && R_ORIGIN=$(clean "$OPT_ORIGIN")
  [[ -n $R_ORIGIN ]] || R_ORIGIN=$(detect_source "$name")
  is_installed "$name" && R_LAST=$(detect_version "$name" "$R_CMD")
  backup_db
  replace_record "$name" "$(make_line "$R_NAME" "$R_CMD" "$R_ORIGIN" "$R_ADDED" "$R_NOTE" "$R_LAST")"
  printf '%s[~]%s updated %s\n' "$YEL" "$RST" "$name"
}

cmd_list() {
  local -a rows=() o_name=() o_stat=() o_ver=() o_org=() o_add=() o_note=() o_cmd=()
  local line stat ver hay i n missing=0
  local filt=${FIND,,} org=${OPT_ORIGIN,,}

  mapfile -t rows < <(all_records)
  for line in "${rows[@]}"; do
    parse_line "$line"
    [[ -z $org || ${R_ORIGIN,,} == "$org" ]] || continue
    if [[ -n $filt ]]; then
      hay="${R_NAME,,} ${R_ORIGIN,,} ${R_NOTE,,}"
      [[ $hay == *"$filt"* ]] || continue
    fi
    if is_installed "$R_NAME"; then
      stat=installed
      if (( OPT_FAST )); then ver=$R_LAST; else ver=$(detect_version "$R_NAME" "$R_CMD"); fi
      ver=${ver:-unknown}
    else
      stat=missing
      ver="-"
      (( missing++ ))
    fi
    o_name+=("$R_NAME"); o_stat+=("$stat"); o_ver+=("$ver")
    o_org+=("${R_ORIGIN:--}"); o_add+=("${R_ADDED:--}"); o_note+=("$R_NOTE"); o_cmd+=("$R_CMD")
  done
  n=${#o_name[@]}

  if (( OPT_JSON )); then
    local comma
    printf '[\n'
    for (( i = 0; i < n; i++ )); do
      comma=","; (( i == n - 1 )) && comma=""
      [[ ${o_ver[i]} == - ]] && o_ver[i]=""
      [[ ${o_org[i]} == - ]] && o_org[i]=""
      [[ ${o_add[i]} == - ]] && o_add[i]=""
      printf '  {"name":"%s","installed":%s,"version":"%s","command":"%s","origin":"%s","added":"%s","note":"%s"}%s\n' \
        "$(jesc "${o_name[i]}")" \
        "$([[ ${o_stat[i]} == installed ]] && echo true || echo false)" \
        "$(jesc "${o_ver[i]}")" "$(jesc "${o_cmd[i]}")" "$(jesc "${o_org[i]}")" \
        "$(jesc "${o_add[i]}")" "$(jesc "${o_note[i]}")" "$comma"
    done
    printf ']\n'
    return 0
  fi

  if (( n == 0 )); then
    if [[ -n $filt || -n $org ]]; then
      info "No matching tools."
    else
      info "No tools tracked yet. Try:  $PROG -a git   or   $PROG -S"
    fi
    return 0
  fi

  local wn=4 ws=6 wv=7 wo=6
  for (( i = 0; i < n; i++ )); do
    (( ${#o_name[i]} > wn )) && wn=${#o_name[i]}
    (( ${#o_stat[i]} > ws )) && ws=${#o_stat[i]}
    (( ${#o_ver[i]}  > wv )) && wv=${#o_ver[i]}
    (( ${#o_org[i]}  > wo )) && wo=${#o_org[i]}
  done
  printf '%s%-*s  %-*s  %-*s  %-*s  %-10s  %s%s\n' \
    "$BLD" "$wn" TOOL "$ws" STATUS "$wv" VERSION "$wo" ORIGIN ADDED NOTE "$RST"
  local col
  for (( i = 0; i < n; i++ )); do
    col=$GRN; [[ ${o_stat[i]} == missing ]] && col=$RED
    printf '%-*s  %s%-*s%s  %-*s  %-*s  %-10s  %s\n' \
      "$wn" "${o_name[i]}" "$col" "$ws" "${o_stat[i]}" "$RST" \
      "$wv" "${o_ver[i]}" "$wo" "${o_org[i]}" "${o_add[i]}" "${o_note[i]}"
  done
  printf '%s%d tool(s)' "$DIM" "$n"
  (( missing )) && printf ', %d missing' "$missing"
  printf '%s\n' "$RST"
}

cmd_tool_version() {
  (( $# )) || die "--tool-version needs a tool name (e.g. $PROG -v npm)"
  local rc=0 name cmd ver
  for name in "$@"; do
    if ! valid_name "$name"; then warn "invalid tool name: '$name'"; rc=1; continue; fi
    if ! is_installed "$name"; then warn "$name: not found in PATH"; rc=1; continue; fi
    cmd=""
    if [[ -f $DB ]] && load_record "$name"; then cmd=$R_CMD; fi
    ver=$(detect_version "$name" "$cmd")
    if [[ -z $ver ]]; then warn "$name: could not determine the version"; rc=1; continue; fi
    if (( OPT_QUIET )); then printf '%s\n' "$ver"; else printf '%s %s\n' "$name" "$ver"; fi
  done
  return $rc
}

kv() { printf '  %s%-16s%s %s\n' "$DIM" "$1" "$RST" "$2"; }

cmd_info() {
  (( $# )) || die "--info needs a tool name"
  local rc=0 name path real ver tracked
  for name in "$@"; do
    if ! valid_name "$name"; then warn "invalid tool name: '$name'"; rc=1; continue; fi
    tracked=0
    load_record "$name" && tracked=1
    path=$(tool_path "$name")
    if (( ! tracked )) && [[ -z $path ]]; then
      warn "$name is neither tracked nor installed"; rc=1; continue
    fi
    printf '%s%s%s\n' "$BLD" "$name" "$RST"
    if (( tracked )); then kv "Tracked" "yes (since ${R_ADDED:-?})"; else kv "Tracked" "no"; R_CMD="" R_ORIGIN="" R_NOTE="" R_LAST=""; fi
    if [[ -n $path ]]; then
      kv "Path" "$path"
      real=$(readlink -f -- "$path" 2>/dev/null)
      [[ -n $real && $real != "$path" ]] && kv "Resolves to" "$real"
      ver=$(detect_version "$name" "$R_CMD")
      kv "Version" "${ver:-unknown}"
    else
      kv "Installed" "${RED}no${RST}"
    fi
    (( tracked )) && kv "Recorded version" "${R_LAST:-unknown}"
    kv "Version command" "${R_CMD:-auto-detect}"
    kv "Origin" "${R_ORIGIN:-$([[ -n $path ]] && detect_source "$name" || echo unknown)}"
    [[ -n $R_NOTE ]] && kv "Note" "$R_NOTE"
  done
  return $rc
}

cmd_check() {
  local -a rows=()
  local line ver w ok=0 miss=0 chg=0
  mapfile -t rows < <(all_records)
  (( ${#rows[@]} )) || { info "No tools tracked yet."; return 0; }
  w=$(printf '%s\n' "${rows[@]}" | maxw)
  for line in "${rows[@]}"; do
    parse_line "$line"
    if ! is_installed "$R_NAME"; then
      printf '%sMISSING%s  %-*s\n' "$RED" "$RST" "$w" "$R_NAME"
      (( miss++ ))
      continue
    fi
    ver=$(detect_version "$R_NAME" "$R_CMD")
    if [[ -n $R_LAST && -n $ver && $ver != "$R_LAST" ]]; then
      printf '%sCHANGED%s  %-*s  %s -> %s\n' "$YEL" "$RST" "$w" "$R_NAME" "$R_LAST" "$ver"
      (( chg++ ))
    else
      printf '%sok     %s  %-*s  %s\n' "$GRN" "$RST" "$w" "$R_NAME" "${ver:-unknown}"
      (( ok++ ))
    fi
  done
  printf '%s%d ok, %d changed, %d missing%s\n' "$DIM" "$ok" "$chg" "$miss" "$RST"
  (( miss == 0 ))
}

cmd_sync() {
  local -a names=("$@")
  local n ver rc=0 changed=0
  (( ${#names[@]} )) || mapfile -t names < <(all_records | cut -f1)
  (( ${#names[@]} )) || { info "No tools tracked yet."; return 0; }
  for n in "${names[@]}"; do
    if ! load_record "$n"; then warn "$n is not tracked"; rc=1; continue; fi
    if ! is_installed "$n"; then warn "$n is not installed - skipped"; continue; fi
    ver=$(detect_version "$n" "$R_CMD")
    if [[ -z $ver ]]; then warn "$n: version unknown - skipped"; continue; fi
    if [[ $ver == "$R_LAST" ]]; then
      (( OPT_QUIET )) || printf '    %s (unchanged, %s)\n' "$n" "$ver"
    else
      replace_record "$n" "$(make_line "$R_NAME" "$R_CMD" "$R_ORIGIN" "$R_ADDED" "$R_NOTE" "$ver")"
      printf '%s[~]%s %s: %s -> %s\n' "$YEL" "$RST" "$n" "${R_LAST:-?}" "$ver"
      (( changed++ ))
    fi
  done
  (( OPT_QUIET )) || printf '%s%d tool(s) updated%s\n' "$DIM" "$changed" "$RST"
  return $rc
}

cmd_find() {
  (( $# == 1 )) || die "--find needs exactly one search term"
  FIND=$1
  cmd_list
}

cmd_scan() {
  local -a found=() dirs=()
  local -A seen=()
  local n d f offpath=0

  for n in "${COMMON_TOOLS[@]}"; do
    [[ -n ${seen[$n]-} ]] && continue
    if is_installed "$n" && ! has_tool "$n"; then found+=("$n"); seen[$n]=1; fi
  done

  dirs=("$HOME/.local/bin" "$HOME/bin" "$HOME/.cargo/bin" "$HOME/go/bin"
        "$HOME/.npm-global/bin" "$HOME/.bun/bin" "$HOME/.deno/bin")
  if is_installed npm; then
    d=$(npm prefix -g 2>/dev/null)
    [[ $d == "$HOME"/* && -d $d/bin ]] && dirs+=("$d/bin")
  fi
  for d in "${dirs[@]}"; do
    [[ -d $d ]] || continue
    for f in "$d"/*; do
      [[ -f $f && -x $f ]] || continue
      n=${f##*/}
      valid_name "$n" || continue
      [[ -n ${seen[$n]-} ]] && continue
      has_tool "$n" && continue
      if is_installed "$n"; then
        seen[$n]=1; found+=("$n")
      else
        (( offpath++ ))
      fi
    done
  done
  (( offpath )) && warn "$offpath executable(s) in your bin directories are not on PATH - skipped"

  if (( ${#found[@]} == 0 )); then
    info "Nothing new found - everything discovered is already tracked."
    return 0
  fi
  mapfile -t found < <(printf '%s\n' "${found[@]}" | sort -f)
  printf 'Found %d untracked tool(s):\n' "${#found[@]}"
  for n in "${found[@]}"; do printf '  %-24s %s\n' "$n" "$(detect_source "$n")"; done
  if ! confirm "Add them all?"; then
    info "Nothing added. Re-run with -y to add without asking."
    return 0
  fi
  for n in "${found[@]}"; do add_one "$n" "" "" ""; done
}

cmd_export() {
  (( $# <= 1 )) || die "--export takes at most one file name"
  if (( $# == 0 )); then
    cat -- "$DB"
  else
    if [[ -e $1 ]] && ! confirm "$1 already exists - overwrite?"; then
      die "not overwriting $1 (use -y to force)"
    fi
    cp -- "$DB" "$1" || die "cannot write $1"
    info "exported $(all_records | wc -l | tr -d ' ') tool(s) to $1"
  fi
}

cmd_import() {
  (( $# == 1 )) || die "--import needs exactly one file name"
  [[ -r $1 ]] || die "cannot read file: $1"
  local line added=0 skipped=0
  backup_db
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
    parse_line "$line"
    if ! valid_name "$R_NAME"; then
      warn "skipping invalid line: ${line:0:40}"; (( skipped++ )); continue
    fi
    if has_tool "$R_NAME"; then (( skipped++ )); continue; fi
    make_line "$R_NAME" "$R_CMD" "$R_ORIGIN" "${R_ADDED:-$(date +%F)}" "$R_NOTE" "$R_LAST" >> "$DB"
    (( added++ ))
  done < "$1"
  info "imported $added tool(s), skipped $skipped"
}

cmd_clear() {
  local n
  n=$(all_records | wc -l | tr -d ' ')
  (( n )) || { info "The list is already empty."; return 0; }
  confirm "Remove ALL $n tool(s) from the list? (a backup is kept as $DB.bak)" \
    || die "aborted (use -y to skip the question)"
  backup_db
  head -n 2 -- "$DB.bak" > "$DB"
  info "removed $n tool(s)"
}

# ------------------------------------------------------- argument parsing --
ACTION=""
ARGS=()
OPT_CMD="" OPT_NOTE="" OPT_ORIGIN="" FIND=""
SET_CMD=0 SET_NOTE=0 SET_ORIGIN=0
OPT_JSON=0 OPT_FAST=0 OPT_QUIET=0 OPT_YES=0

set_action() {
  [[ -z $ACTION || $ACTION == "$1" ]] || die "only one action at a time (got '$ACTION' and '$1')"
  ACTION=$1
}

need_val() { (( $2 >= 2 )) || die "option $1 needs a value"; }

parse_args() {
  while (( $# )); do
    case $1 in
      --*=*)  set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;                 # --note=text
      -[A-Za-z][A-Za-z]*) set -- "-${1:1:1}" "-${1:2}" "${@:2}"; continue ;;   # -lj  -> -l -j
      -h|--help)            set_action help ;;
      -V|--version)         set_action version ;;
      -a|--add)             set_action add ;;
      -r|--remove|--rm)     set_action remove ;;
      -e|--edit)            set_action edit ;;
      -l|--list)            set_action list ;;
      -v|--tool-version)    set_action toolver ;;
      -i|--info)            set_action info ;;
      -k|--check)           set_action check ;;
      -s|--sync)            set_action sync ;;
      -f|--find)            set_action find ;;
      -S|--scan)            set_action scan ;;
      -x|--export)          set_action export ;;
      -I|--import)          set_action import ;;
      --count)              set_action count ;;
      --path)               set_action path ;;
      --clear)              set_action clear ;;
      -c|--cmd)    need_val "$1" $#; OPT_CMD=$2;    SET_CMD=1;    shift ;;
      -n|--note)   need_val "$1" $#; OPT_NOTE=$2;   SET_NOTE=1;   shift ;;
      -o|--origin) need_val "$1" $#; OPT_ORIGIN=$2; SET_ORIGIN=1; shift ;;
      -j|--json)            OPT_JSON=1 ;;
      -F|--fast)            OPT_FAST=1 ;;
      -q|--quiet)           OPT_QUIET=1 ;;
      -y|--yes)             OPT_YES=1 ;;
      --)                   shift; ARGS+=("$@"); break ;;
      -*)                   die "unknown option: $1 (see: $PROG --help)" ;;
      *)                    ARGS+=("$1") ;;
    esac
    shift
  done
}

main() {
  if (( $# == 0 )); then usage; exit 0; fi
  parse_args "$@"
  set -- "${ARGS[@]}"

  [[ -n $ACTION ]] || die "no action given (try: $PROG --help)"

  case $ACTION in
    help)    usage; return 0 ;;
    version) echo "$PROG $CLITRACK_VERSION"; return 0 ;;
    path)    echo "$DB"; return 0 ;;
    toolver) cmd_tool_version "$@"; return $? ;;
  esac

  init_db
  case $ACTION in
    add)     cmd_add "$@" ;;
    remove)  cmd_remove "$@" ;;
    edit)    cmd_edit "$@" ;;
    list)    cmd_list ;;
    info)    cmd_info "$@" ;;
    check)   cmd_check ;;
    sync)    cmd_sync "$@" ;;
    find)    cmd_find "$@" ;;
    scan)    cmd_scan ;;
    export)  cmd_export "$@" ;;
    import)  cmd_import "$@" ;;
    count)   all_records | wc -l | tr -d ' ' ;;
    clear)   cmd_clear ;;
  esac
}

main "$@"
