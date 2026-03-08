#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════╗
# ║           nixpkg — NixOS TUI pkg manager         ║
# ║   Supports: flakes (home-manager / NixOS)        ║
# ║             nix-env (imperative)                 ║
# ║             configuration.nix (declarative)      ║
# ╚══════════════════════════════════════════════════╝
#
# Depends: bash ≥4, ncurses (tput), nix

set -o pipefail

# ─────────────────────────────────────────────────────────────
# Terminal / drawing helpers
# ─────────────────────────────────────────────────────────────
ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"

fg(){ printf "${ESC}[38;5;${1}m"; }   # fg 256-color
bg(){ printf "${ESC}[48;5;${1}m"; }   # bg 256-color
CLR_EOL="${ESC}[K"
HIDE_CURSOR="${ESC}[?25l"
SHOW_CURSOR="${ESC}[?25h"
SAVE_POS="${ESC}7"
REST_POS="${ESC}8"

# color palette
C_NIX="$(fg 81)"           # cyan-ish  — nix snowflake
C_GREEN="$(fg 114)"        # soft green
C_CYAN="$(fg 81)"          # cyan — version highlight
C_YELLOW="$(fg 221)"       # warm yellow
C_RED="$(fg 203)"          # salmon red
C_ACCENT="$(fg 75)"        # blue accent
C_MUTED="$(fg 242)"        # dark grey
C_WHITE="$(fg 255)"
C_SEL_BG="$(bg 236)"       # selection background
C_HDR_BG="$(bg 234)"       # panel header bg
C_BORDER="$(fg 238)"

move(){ printf "${ESC}[${1};${2}H"; }
clear_screen(){ printf "${ESC}[2J"; }

draw_hline(){
  local row=$1 col=$2 len=$3 char="${4:-─}"
  move "$row" "$col"
  printf "${C_BORDER}%s${RESET}" "$(printf "%${len}s" | tr ' ' "$char")"
}
draw_vline(){
  local row=$1 col=$2 len=$3
  local r
  for((r=0;r<len;r++)); do
    move $((row+r)) "$col"
    printf "${C_BORDER}│${RESET}"
  done
}

box(){
  # box row col height width [title]
  local r=$1 c=$2 h=$3 w=$4 title="${5:-}"
  local inner=$((w-2))
  move "$r" "$c"; printf "${C_BORDER}┌%s┐${RESET}" "$(printf "%${inner}s" | tr ' ' '─')"
  local i
  for((i=1;i<h-1;i++)); do
    move $((r+i)) "$c"; printf "${C_BORDER}│${RESET}"
    move $((r+i)) $((c+w-1)); printf "${C_BORDER}│${RESET}"
  done
  move $((r+h-1)) "$c"; printf "${C_BORDER}└%s┘${RESET}" "$(printf "%${inner}s" | tr ' ' '─')"
  if [[ -n "$title" ]]; then
    move "$r" $((c+2))
    printf "${C_HDR_BG}${BOLD}${C_ACCENT} %s ${RESET}" "$title"
  fi
}

pad_right(){
  local str="$1" width="$2"
  local visible
  # strip ANSI escapes for length calculation
  visible=$(printf '%s' "$str" | sed 's/\x1b\[[0-9;]*m//g')
  local pad=$((width - ${#visible}))
  [[ $pad -lt 0 ]] && pad=0
  printf '%s%*s' "$str" "$pad" ''
}

trunc(){
  local str="$1" max="$2"
  [[ ${#str} -gt $max ]] && str="${str:0:$((max-1))}…"
  printf '%s' "$str"
}

# ─────────────────────────────────────────────────────────────
# Terminal size
# ─────────────────────────────────────────────────────────────
TERM_H=0; TERM_W=0
get_term_size(){
  TERM_H=$(tput lines)
  TERM_W=$(tput cols)
}

# ─────────────────────────────────────────────────────────────
# Mode detection
# ─────────────────────────────────────────────────────────────
MODE=""           # flakes | configuration | imperative
FLAKE_PATH=""     # path to flake.nix
CONF_PATH=""      # path to configuration.nix
HM_PATH=""        # path to home-manager config (flakes)

detect_mode(){
  # 1. NixOS flakes?
  if [[ -f /etc/nixos/flake.nix ]]; then
    MODE="flakes"
    FLAKE_PATH="/etc/nixos/flake.nix"
    # home-manager inside flake?
    if [[ -f "$HOME/.config/home-manager/flake.nix" ]]; then
      HM_PATH="$HOME/.config/home-manager/flake.nix"
    elif [[ -f /etc/nixos/home.nix ]]; then
      HM_PATH="/etc/nixos/home.nix"
    fi
  # 2. Plain configuration.nix?
  elif [[ -f /etc/nixos/configuration.nix ]]; then
    MODE="configuration"
    CONF_PATH="/etc/nixos/configuration.nix"
  else
    # 3. Fallback — imperative nix-env
    MODE="imperative"
  fi
  # Export so background subshells can see them
  export MODE CONF_PATH FLAKE_PATH HM_PATH
}

mode_label(){
  case "$MODE" in
    flakes)        echo "❄  Flakes (${FLAKE_PATH})" ;;
    configuration) echo "  configuration.nix (${CONF_PATH})" ;;
    imperative)    echo "  nix-env (imperative)" ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Package operations  (per-mode)
# ─────────────────────────────────────────────────────────────

# ── list installed ──────────────────────────────────────────
list_installed(){
  case "$MODE" in
    flakes|configuration)
      # Installed in current system profile
      nix-store -qR /run/current-system 2>/dev/null \
        | grep -oP '(?<=-)[a-zA-Z][^/]+(?=-)' \
        | sort -u \
        | head -400 \
        || true
      # Also show user packages from nix-env
      nix-env -q 2>/dev/null | awk '{print $1}' || true
      ;;
    imperative)
      nix-env -q 2>/dev/null | awk '{print $1}' || true
      ;;
  esac
}

parse_nix_packages_from_file(){
  # Parses both styles:
  #   environment.systemPackages = with pkgs; [ git firefox ];
  #   environment.systemPackages = [ pkgs.git pkgs.firefox ];
  # Prints: name\t\t(in config)
  local file="$1"
  [[ -z "$file" || ! -f "$file" ]] && return
  python3 - "$file" <<'PYEOF'
import sys, re

path = sys.argv[1]
try:
    content = open(path).read()
except Exception as e:
    print(f"ERROR reading {path}: {e}", file=sys.stderr)
    sys.exit(1)

found = set()

# Style 1: pkgs.something  (anywhere in file)
for m in re.finditer(r'\bpkgs\.([a-zA-Z0-9_][a-zA-Z0-9_\-]*)', content):
    found.add(m.group(1))

# Style 2: with pkgs; [ foo bar baz ]  — bare names inside the bracket block
for block_m in re.finditer(
    r'(?:environment\.systemPackages|home\.packages)\s*=\s*with\s+pkgs\s*;\s*\[(.*?)\]',
    content, re.DOTALL
):
    block = block_m.group(1)
    # strip comments
    block = re.sub(r'#[^\n]*', '', block)
    for name in re.findall(r'\b([a-zA-Z][a-zA-Z0-9_\-]*)\b', block):
        if name not in ('with', 'pkgs', 'let', 'in', 'if', 'then', 'else', 'rec', 'inherit'):
            found.add(name)

for name in sorted(found):
    print(f"{name}\t\t(in config)")
PYEOF
}

list_installed_with_version(){
  case "$MODE" in
    flakes|configuration)
      # Find config file — do it inline here so MODE/CONF_PATH are available
      local pkgs_file=""
      local search_dirs=()

      if [[ "$MODE" == "flakes" ]]; then
        search_dirs=("/etc/nixos" "$HOME/.config/nixos" "$HOME/.config/home-manager" "$HOME/nixos" "$HOME/.dotfiles")
      else
        search_dirs=("/etc/nixos")
      fi

      # Search all .nix files for packages declaration
      for d in "${search_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r f; do
          if grep -qE '(environment\.systemPackages|home\.packages)\s*=' "$f" 2>/dev/null; then
            pkgs_file="$f"
            break 2
          fi
        done < <(find "$d" -maxdepth 3 -name '*.nix' 2>/dev/null)
      done

      if [[ -n "$pkgs_file" ]]; then
        parse_nix_packages_from_file "$pkgs_file"
      else
        # Fallback: try CONF_PATH directly even if pattern not found
        [[ -n "${CONF_PATH:-}" && -f "$CONF_PATH" ]] && parse_nix_packages_from_file "$CONF_PATH"
      fi

      # Also show any imperatively installed packages (nix-env)
      local json
      json=$(nix-env -q --json 2>/dev/null || true)
      if [[ -n "$json" && "$json" != "{}" ]]; then
        printf '%s' "$json" | python3 -c "
import sys,json
raw=sys.stdin.read().strip()
if not raw or raw=='{}': sys.exit(0)
try:
    d=json.loads(raw)
except: sys.exit(0)
for k,v in d.items():
    name=v.get('name',k)
    ver=v.get('version','')
    desc=v.get('meta',{}).get('description','')[:60]
    print(f'{name}\t{ver}\t{desc}')
" 2>/dev/null || true
      fi
      ;;
    imperative)
      local json
      json=$(nix-env -q --json 2>/dev/null || true)
      if [[ -n "$json" && "$json" != "{}" ]]; then
        printf '%s' "$json" | python3 -c "
import sys,json
raw=sys.stdin.read().strip()
if not raw or raw=='{}': sys.exit(0)
try:
    d=json.loads(raw)
except: sys.exit(0)
for k,v in d.items():
    name=v.get('name',k)
    ver=v.get('version','')
    desc=v.get('meta',{}).get('description','')[:60]
    print(f'{name}\t{ver}\t{desc}')
" 2>/dev/null || true
      fi
      ;;
  esac
}

# ── search ──────────────────────────────────────────────────
search_pkgs(){
  local q="$1" out="" err="" rc=0
  [[ -z "$q" ]] && return

  # Run nix search with timeout, capture both streams
  local tmp_out tmp_err
  tmp_out=$(mktemp)
  tmp_err=$(mktemp)

  timeout 30 nix search nixpkgs "$q" --json >"$tmp_out" 2>"$tmp_err"
  rc=$?

  if [[ $rc -eq 124 ]]; then
    echo "ERROR:Search timed out after 30s. Try a more specific query." >&2
    rm -f "$tmp_out" "$tmp_err"
    return 1
  fi

  local err_content
  err_content=$(cat "$tmp_err")
  rm -f "$tmp_err"

  if [[ -n "$err_content" ]]; then
    echo "$err_content" >&2
  fi

  local out_content
  out_content=$(cat "$tmp_out")
  rm -f "$tmp_out"

  if [[ -z "$out_content" || "$out_content" == "{}" ]]; then
    return 0
  fi

  python3 -c "
import sys, json
raw = sys.stdin.read().strip()
if not raw or raw == '{}':
    sys.exit(0)
try:
    d = json.loads(raw)
except json.JSONDecodeError as e:
    print(f'JSON parse error: {e}', file=sys.stderr)
    sys.exit(1)
for k, v in list(d.items())[:150]:
    name = k.split('.')[-1]
    ver  = v.get('version', '')
    desc = v.get('description', '')[:70]
    print(f'{name}\t{ver}\t{desc}')
" <<< "$out_content"
}

# ─────────────────────────────────────────────────────────────
# Config file editing helpers
# ─────────────────────────────────────────────────────────────

# Find the nix file that contains environment.systemPackages or home.packages
# Returns path to the file, or empty string
find_packages_file(){
  local candidates=()

  if [[ "$MODE" == "flakes" ]]; then
    # Common locations for home-manager or NixOS flake configs
    local dirs=("/etc/nixos" "$HOME/.config/nixos" "$HOME/.config/home-manager" "$HOME/nixos" "$HOME/.dotfiles")
    for d in "${dirs[@]}"; do
      [[ -d "$d" ]] || continue
      while IFS= read -r f; do
        candidates+=("$f")
      done < <(find "$d" -maxdepth 3 -name '*.nix' 2>/dev/null)
    done
  elif [[ "$MODE" == "configuration" ]]; then
    candidates+=("$CONF_PATH")
    # also check imports
    while IFS= read -r f; do
      candidates+=("$f")
    done < <(find /etc/nixos -maxdepth 2 -name '*.nix' 2>/dev/null)
  fi

  # Return first file that contains a packages list
  for f in "${candidates[@]}"; do
    if grep -qE '(environment\.systemPackages|home\.packages)\s*=' "$f" 2>/dev/null; then
      echo "$f"
      return
    fi
  done
}

# Add pkgs.<name> into the packages list in a .nix file
# Strategy: find the closing ]; of the packages list and insert before it
conf_add_package(){
  local file="$1" pkg="$2"

  # Check not already present
  if grep -qP "\bpkgs\.${pkg}\b" "$file" 2>/dev/null; then
    echo "Package pkgs.${pkg} already present in ${file}"
    return 0
  fi

  # Make a backup
  cp "$file" "${file}.nixpkg.bak"

  # Use python3 for reliable multi-line editing
  python3 - "$file" "$pkg" <<'PYEOF'
import sys, re

path = sys.argv[1]
pkg  = sys.argv[2]

with open(path) as f:
    content = f.read()

# Find environment.systemPackages or home.packages list block
# We look for the pattern:   packages = [  ... ];
# and insert our line just before the closing ];
pattern = re.compile(
    r'((?:environment\.systemPackages|home\.packages)\s*=\s*(?:with\s+pkgs\s*;)?\s*\[)(.*?)(\];)',
    re.DOTALL
)

m = pattern.search(content)
if not m:
    print(f"ERROR: Could not find packages list in {path}", file=sys.stderr)
    sys.exit(1)

before = m.group(1)
inner  = m.group(2)
after  = m.group(3)

# Detect indentation from existing entries
indent = "    "
for line in inner.splitlines():
    stripped = line.lstrip()
    if stripped.startswith("pkgs.") or stripped.startswith("#"):
        indent = line[: len(line) - len(stripped)]
        break

new_inner = inner.rstrip('\n') + f"\n{indent}pkgs.{pkg}\n"
new_content = content[:m.start()] + before + new_inner + after + content[m.end():]

with open(path, 'w') as f:
    f.write(new_content)

print(f"Added pkgs.{pkg} to {path}")
PYEOF
}

# Remove pkgs.<name> from the packages list in a .nix file
conf_remove_package(){
  local file="$1" pkg="$2"

  if ! grep -qP "\bpkgs\.${pkg}\b" "$file" 2>/dev/null; then
    echo "Package pkgs.${pkg} not found in ${file}"
    return 1
  fi

  cp "$file" "${file}.nixpkg.bak"

  python3 - "$file" "$pkg" <<'PYEOF'
import sys, re

path = sys.argv[1]
pkg  = sys.argv[2]

with open(path) as f:
    lines = f.readlines()

out = []
removed = 0
for line in lines:
    # Match lines like:  pkgs.foo  or  pkgs.foo  # comment
    if re.search(rf'\bpkgs\.{re.escape(pkg)}\b', line):
        removed += 1
        continue
    out.append(line)

if removed == 0:
    print(f"ERROR: pkgs.{pkg} not found", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.writelines(out)

print(f"Removed pkgs.{pkg} from {path} ({removed} line(s))")
PYEOF
}

# ── install ─────────────────────────────────────────────────
install_pkg(){
  local name="$1"
  case "$MODE" in
    flakes)
      local pkgs_file
      pkgs_file=$(find_packages_file)
      if [[ -n "$pkgs_file" ]]; then
        echo "Editing: ${pkgs_file}"
        conf_add_package "$pkgs_file" "$name" || { echo "Edit failed"; exit 1; }
        echo "Running: sudo nixos-rebuild switch (or home-manager switch)..."
        # Detect which rebuild command to use
        if grep -q 'home\.packages' "$pkgs_file" 2>/dev/null; then
          home-manager switch 2>&1
        else
          sudo nixos-rebuild switch 2>&1
        fi
      else
        echo "No packages list found in flake config, falling back to nix profile"
        nix profile install "nixpkgs#${name}" 2>&1
      fi
      ;;
    configuration)
      local pkgs_file
      pkgs_file=$(find_packages_file)
      if [[ -z "$pkgs_file" ]]; then
        pkgs_file="$CONF_PATH"
      fi
      echo "Editing: ${pkgs_file}"
      conf_add_package "$pkgs_file" "$name" || { echo "Edit failed"; exit 1; }
      echo "Running: sudo nixos-rebuild switch..."
      sudo nixos-rebuild switch 2>&1
      ;;
    imperative)
      nix-env -iA "nixpkgs.${name}" 2>&1
      ;;
  esac
}

# ── remove ──────────────────────────────────────────────────
remove_pkg(){
  local name="$1"
  case "$MODE" in
    flakes)
      local pkgs_file
      pkgs_file=$(find_packages_file)
      if [[ -n "$pkgs_file" ]] && grep -qP "\bpkgs\.${name}\b" "$pkgs_file" 2>/dev/null; then
        echo "Editing: ${pkgs_file}"
        conf_remove_package "$pkgs_file" "$name" || { echo "Edit failed"; exit 1; }
        if grep -q 'home\.packages' "$pkgs_file" 2>/dev/null; then
          home-manager switch 2>&1
        else
          sudo nixos-rebuild switch 2>&1
        fi
      else
        # Try nix profile
        local idx
        idx=$(nix profile list 2>/dev/null | grep -i "$name" | awk '{print $1}' | head -1)
        if [[ -n "$idx" ]]; then
          echo "Removing from nix profile (index ${idx})..."
          nix profile remove "$idx" 2>&1
        else
          nix-env -e "$name" 2>&1
        fi
      fi
      ;;
    configuration)
      local pkgs_file
      pkgs_file=$(find_packages_file)
      if [[ -z "$pkgs_file" ]]; then
        pkgs_file="$CONF_PATH"
      fi
      echo "Editing: ${pkgs_file}"
      conf_remove_package "$pkgs_file" "$name" || { echo "Edit failed"; exit 1; }
      echo "Running: sudo nixos-rebuild switch..."
      sudo nixos-rebuild switch 2>&1
      ;;
    imperative)
      nix-env -e "$name" 2>&1
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# State
# ─────────────────────────────────────────────────────────────
declare -a INST_LIST=()    # "name\tversion\tdesc"
declare -a SRCH_LIST=()    # same
declare -a LOG_LINES=()

FOCUS=0          # 0=installed 1=search 2=log
INST_SEL=0
INST_SCR=0
SRCH_SEL=0
SRCH_SCR=0
LOG_SCR=0
SEARCH_QUERY=""
SEARCH_MODE=0    # 1 = typing query
STATUS_MSG=""
STATUS_COLOR=""
LOADING=0
LOADING_MSG=""

log_op(){
  LOG_LINES+=("$1")
  LOG_SCR=$(( ${#LOG_LINES[@]} > 1 ? ${#LOG_LINES[@]} - 1 : 0 ))
}

# ─────────────────────────────────────────────────────────────
# Layout computation
# ─────────────────────────────────────────────────────────────
# Returns: LTOP LBOT RIGHT (row/col/h/w for each panel)
layout(){
  get_term_size
  local H=$TERM_H W=$TERM_W
  local lw=$(( W * 2 / 5 ))
  local rw=$(( W - lw ))
  local top_h=$(( (H - 3) / 2 ))
  local bot_h=$(( H - 3 - top_h ))
  # panels: row col h w
  PANEL_INST_R=2;       PANEL_INST_C=1;    PANEL_INST_H=$top_h;  PANEL_INST_W=$lw
  PANEL_SRCH_R=$((2+top_h)); PANEL_SRCH_C=1; PANEL_SRCH_H=$bot_h; PANEL_SRCH_W=$lw
  PANEL_LOG_R=2;        PANEL_LOG_C=$((lw+1)); PANEL_LOG_H=$((H-3)); PANEL_LOG_W=$rw
}

# ─────────────────────────────────────────────────────────────
# Drawing
# ─────────────────────────────────────────────────────────────
draw_topbar(){
  move 1 1
  printf "${C_HDR_BG}${BOLD}${C_NIX} ❄  nixpkg ${RESET}"
  printf "${C_HDR_BG}${C_MUTED} $(mode_label) ${RESET}"
  printf "${C_HDR_BG}${CLR_EOL}${RESET}"
}

draw_bottombar(){
  move $((TERM_H)) 1
  if [[ $LOADING -eq 1 ]]; then
    printf "${C_HDR_BG}${C_YELLOW}${BOLD} ⟳  ${LOADING_MSG}… ${RESET}${CLR_EOL}"
  else
    printf "${C_HDR_BG}${STATUS_COLOR}${BOLD} ${STATUS_MSG} ${RESET}"
    local hints
    hints="${C_MUTED} [tab]panel  [j/k]move  [/]search  [i]install  [d]remove  [r]reload  [q]quit${RESET}"
    printf "%s${CLR_EOL}" "$hints"
  fi
}

draw_panel_installed(){
  local r=$PANEL_INST_R c=$PANEL_INST_C h=$PANEL_INST_H w=$PANEL_INST_W
  local title="Installed"
  [[ $FOCUS -eq 0 ]] && title="${C_ACCENT}${BOLD}Installed${RESET}" || title="${C_MUTED}Installed${RESET}"
  box $r $c $h $w " $title "

  local inner_h=$(( h - 2 ))
  local inner_w=$(( w - 4 ))
  local total=${#INST_LIST[@]}

  if [[ $total -eq 0 ]]; then
    move $((r+2)) $((c+2))
    printf "${C_YELLOW}No packages found${RESET}"
    return
  fi

  local i
  for((i=0; i<inner_h && i<total; i++)); do
    local idx=$(( INST_SCR + i ))
    [[ $idx -ge $total ]] && break
    local row=$(( r + 1 + i ))
    local line="${INST_LIST[$idx]}"
    local name ver desc
    IFS=$'\t' read -r name ver desc <<< "$line"
    name=$(trunc "$name" 22)
    ver=$(trunc "$ver"   10)

    move "$row" $((c+1))
    printf "${CLR_EOL}"
    move "$row" $((c+2))

    if [[ $idx -eq $INST_SEL && $FOCUS -eq 0 ]]; then
      printf "${C_SEL_BG}${C_WHITE}${BOLD}▶ %-22s %-10s${RESET}" "$name" "$ver"
    else
      printf "${C_GREEN}✓ ${RESET}${C_WHITE}%-22s${RESET} ${C_MUTED}%-10s${RESET}" "$name" "$ver"
    fi
  done

  # count
  move $((r+h-1)) $((c+w-10))
  printf "${C_MUTED} %d/%d ${RESET}" $(( INST_SEL+1 )) "$total"
}

draw_panel_search(){
  local r=$PANEL_SRCH_R c=$PANEL_SRCH_C h=$PANEL_SRCH_H w=$PANEL_SRCH_W
  local title
  [[ $FOCUS -eq 1 ]] && title="${C_ACCENT}${BOLD}Search nixpkgs${RESET}" || title="${C_MUTED}Search nixpkgs${RESET}"
  box $r $c $h $w " $title "

  # search input line
  move $((r+1)) $((c+2))
  printf "${CLR_EOL}"
  move $((r+1)) $((c+2))
  if [[ $SEARCH_MODE -eq 1 ]]; then
    printf "${C_YELLOW}/ %s_${RESET}" "$SEARCH_QUERY"
  else
    printf "${C_MUTED}/ %s${RESET}" "$SEARCH_QUERY"
  fi

  local inner_h=$(( h - 3 ))
  local total=${#SRCH_LIST[@]}

  local i
  for((i=0; i<inner_h && i<total; i++)); do
    local idx=$(( SRCH_SCR + i ))
    [[ $idx -ge $total ]] && break
    local row=$(( r + 2 + i ))
    local line="${SRCH_LIST[$idx]}"
    local name ver desc
    IFS=$'\t' read -r name ver desc <<< "$line"
    name=$(trunc "$name" 22)
    ver=$(trunc "$ver"   9)

    move "$row" $((c+1))
    printf "${CLR_EOL}"
    move "$row" $((c+2))

    if [[ $idx -eq $SRCH_SEL && $FOCUS -eq 1 ]]; then
      printf "${C_SEL_BG}${C_WHITE}${BOLD}▶ %-22s %-9s${RESET}" "$name" "$ver"
    else
      printf "  ${C_WHITE}%-22s${RESET} ${C_MUTED}%-9s${RESET}" "$name" "$ver"
    fi
  done

  if [[ $total -gt 0 ]]; then
    move $((r+h-1)) $((c+w-10))
    printf "${C_MUTED} %d/%d ${RESET}" $(( SRCH_SEL+1 )) "$total"
  fi
}

draw_panel_log(){
  local r=$PANEL_LOG_R c=$PANEL_LOG_C h=$PANEL_LOG_H w=$PANEL_LOG_W
  local title
  [[ $FOCUS -eq 2 ]] && title="${C_ACCENT}${BOLD}Info / Log${RESET}" || title="${C_MUTED}Info / Log${RESET}"
  box $r $c $h $w " $title "

  local inner_w=$(( w - 4 ))

  # ── selected package detail ──
  local detail_lines=0
  local pkg_line=""
  if [[ $FOCUS -eq 0 && ${#INST_LIST[@]} -gt 0 && $INST_SEL -lt ${#INST_LIST[@]} ]]; then
    pkg_line="${INST_LIST[$INST_SEL]}"
  elif [[ $FOCUS -eq 1 && ${#SRCH_LIST[@]} -gt 0 && $SRCH_SEL -lt ${#SRCH_LIST[@]} ]]; then
    pkg_line="${SRCH_LIST[$SRCH_SEL]}"
  fi

  if [[ -n "$pkg_line" ]]; then
    local name ver desc
    IFS=$'\t' read -r name ver desc <<< "$pkg_line"
    move $((r+1)) $((c+2))
    printf "${CLR_EOL}"
    move $((r+1)) $((c+2))
    printf "${C_GREEN}${BOLD}%-24s${RESET} ${C_CYAN}v%s${RESET}" "$(trunc "$name" 24)" "$ver"
    move $((r+2)) $((c+2))
    printf "${CLR_EOL}"
    move $((r+2)) $((c+2))
    printf "${C_MUTED}%s${RESET}" "$(trunc "${desc:-(no description)}" $inner_w)"
    # separator
    local sep_y=$((r+3))
    move "$sep_y" $((c+1))
    printf "${C_BORDER}$(printf "%$((w-2))s" | tr ' ' '─')${RESET}"
    detail_lines=3
  fi

  # ── log area ──
  local log_start=$(( r + 1 + detail_lines + (detail_lines>0?1:0) ))
  local log_area=$(( h - 2 - detail_lines - (detail_lines>0?1:0) ))
  local total_log=${#LOG_LINES[@]}

  local i
  for((i=0; i<log_area; i++)); do
    local row=$((log_start+i))
    local idx=$(( LOG_SCR + i ))
    move "$row" $((c+1))
    printf "${CLR_EOL}"
    [[ $idx -ge $total_log ]] && continue
    move "$row" $((c+2))

    local logline="${LOG_LINES[$idx]}"
    local color="$C_MUTED"
    [[ "$logline" == *"✓"* ]]  && color="$C_GREEN"
    [[ "$logline" == *"✗"* ]]  && color="$C_RED"
    [[ "$logline" == *"…"* || "$logline" == *"..."* ]] && color="$C_YELLOW"
    [[ "$logline" == "Tip:"* ]] && color="$C_ACCENT"

    printf "%s%s${RESET}" "$color" "$(trunc "$logline" $inner_w)"
  done
}

full_redraw(){
  layout
  draw_topbar
  draw_panel_installed
  draw_panel_search
  draw_panel_log
  draw_bottombar
}

# ─────────────────────────────────────────────────────────────
# Navigation helpers
# ─────────────────────────────────────────────────────────────
clamp(){
  local val=$1 min=$2 max=$3
  (( val < min )) && val=$min
  (( val > max )) && val=$max
  echo $val
}

nav_up(){
  if [[ $FOCUS -eq 0 ]]; then
    (( INST_SEL > 0 )) && (( INST_SEL-- ))
    (( INST_SEL < INST_SCR )) && INST_SCR=$INST_SEL
  elif [[ $FOCUS -eq 1 ]]; then
    (( SRCH_SEL > 0 )) && (( SRCH_SEL-- ))
    (( SRCH_SEL < SRCH_SCR )) && SRCH_SCR=$SRCH_SEL
  elif [[ $FOCUS -eq 2 ]]; then
    (( LOG_SCR > 0 )) && (( LOG_SCR-- ))
  fi
}

nav_down(){
  if [[ $FOCUS -eq 0 ]]; then
    local max=$(( ${#INST_LIST[@]} - 1 ))
    (( max < 0 )) && return
    (( INST_SEL < max )) && (( INST_SEL++ ))
    local vis=$(( PANEL_INST_H - 2 ))
    (( INST_SEL >= INST_SCR + vis )) && INST_SCR=$(( INST_SEL - vis + 1 ))
  elif [[ $FOCUS -eq 1 ]]; then
    local max=$(( ${#SRCH_LIST[@]} - 1 ))
    (( max < 0 )) && return
    (( SRCH_SEL < max )) && (( SRCH_SEL++ ))
    local vis=$(( PANEL_SRCH_H - 3 ))
    (( SRCH_SEL >= SRCH_SCR + vis )) && SRCH_SCR=$(( SRCH_SEL - vis + 1 ))
  elif [[ $FOCUS -eq 2 ]]; then
    local max=$(( ${#LOG_LINES[@]} - 1 ))
    (( LOG_SCR < max )) && (( LOG_SCR++ ))
  fi
}

go_top(){
  [[ $FOCUS -eq 0 ]] && INST_SEL=0 && INST_SCR=0
  [[ $FOCUS -eq 1 ]] && SRCH_SEL=0 && SRCH_SCR=0
  [[ $FOCUS -eq 2 ]] && LOG_SCR=0
}

go_bottom(){
  if [[ $FOCUS -eq 0 && ${#INST_LIST[@]} -gt 0 ]]; then
    INST_SEL=$(( ${#INST_LIST[@]} - 1 ))
  elif [[ $FOCUS -eq 1 && ${#SRCH_LIST[@]} -gt 0 ]]; then
    SRCH_SEL=$(( ${#SRCH_LIST[@]} - 1 ))
  elif [[ $FOCUS -eq 2 && ${#LOG_LINES[@]} -gt 0 ]]; then
    LOG_SCR=$(( ${#LOG_LINES[@]} - 1 ))
  fi
}

# ─────────────────────────────────────────────────────────────
# Async helpers  (background subshell + temp file)
# ─────────────────────────────────────────────────────────────
TMPDIR_NIXPKG=$(mktemp -d)
RESULT_FILE="$TMPDIR_NIXPKG/result"
BG_PID=""

bg_start(){
  LOADING=1; LOADING_MSG="$1"
  rm -f "$RESULT_FILE"
}

bg_wait(){
  # returns 0 if job finished
  [[ -z "$BG_PID" ]] && return 0
  if ! kill -0 "$BG_PID" 2>/dev/null; then
    BG_PID=""
    LOADING=0
    return 0
  fi
  return 1
}

cleanup(){
  printf "%s" "$SHOW_CURSOR"
  tput rmcup 2>/dev/null || true
  rm -rf "$TMPDIR_NIXPKG"
  [[ -n "$BG_PID" ]] && kill "$BG_PID" 2>/dev/null || true
  stty echo 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────
# Operations
# ─────────────────────────────────────────────────────────────
load_installed(){
  bg_start "Loading installed packages"
  local result_file="$RESULT_FILE"
  local mode="$MODE"
  local conf_path="${CONF_PATH:-}"
  local home_dir="$HOME"

  python3 - "$result_file" "$mode" "$conf_path" "$home_dir" <<'PYEOF' &
import sys, re, subprocess, json, os

result_file = sys.argv[1]
mode        = sys.argv[2]
conf_path   = sys.argv[3]
home_dir    = sys.argv[4]

results = {}  # name -> (version, desc)

# ── 1. Parse declared packages from nix config ──────────────
def find_packages_file():
    if mode in ('flakes', 'configuration'):
        search_dirs = ['/etc/nixos']
        if mode == 'flakes':
            search_dirs += [
                os.path.join(home_dir, '.config/nixos'),
                os.path.join(home_dir, '.config/home-manager'),
                os.path.join(home_dir, 'nixos'),
                os.path.join(home_dir, '.dotfiles'),
            ]
        for d in search_dirs:
            if not os.path.isdir(d):
                continue
            for root, dirs, files in os.walk(d):
                # limit depth
                depth = root[len(d):].count(os.sep)
                if depth >= 3:
                    dirs[:] = []
                    continue
                for fname in files:
                    if not fname.endswith('.nix'):
                        continue
                    fpath = os.path.join(root, fname)
                    try:
                        content = open(fpath).read()
                        if re.search(r'(environment\.systemPackages|home\.packages)\s*=', content):
                            return fpath, content
                    except:
                        pass
    # fallback: try conf_path directly
    if conf_path and os.path.isfile(conf_path):
        try:
            return conf_path, open(conf_path).read()
        except:
            pass
    return None, None

if mode in ('flakes', 'configuration'):
    fpath, content = find_packages_file()
    if content:
        # Style 1: pkgs.something
        for m in re.finditer(r'\bpkgs\.([a-zA-Z0-9][a-zA-Z0-9_\-]*)', content):
            results[m.group(1)] = ('', 'in config')

        # Style 2: with pkgs; [ foo bar ]  — extract bare names from inside brackets
        for block_m in re.finditer(
            r'(?:environment\.systemPackages|home\.packages)\s*=\s*(?:\w+\s+)*with\s+pkgs\s*;\s*\[(.*?)\]',
            content, re.DOTALL
        ):
            block = re.sub(r'#[^\n]*', '', block_m.group(1))  # strip comments
            for name in re.findall(r'\b([a-zA-Z][a-zA-Z0-9_\-]*)\b', block):
                if name not in ('with','pkgs','let','in','if','then','else','rec','inherit','null','true','false'):
                    results[name] = ('', 'in config')

        # Style 3: with pkgs; [ foo bar ] without leading keyword
        for block_m in re.finditer(
            r'(?:environment\.systemPackages|home\.packages)\s*=\s*with\s+pkgs\s*;\s*\[(.*?)\]',
            content, re.DOTALL
        ):
            block = re.sub(r'#[^\n]*', '', block_m.group(1))
            for name in re.findall(r'\b([a-zA-Z][a-zA-Z0-9_\-]*)\b', block):
                if name not in ('with','pkgs','let','in','if','then','else','rec','inherit','null','true','false'):
                    results[name] = ('', 'in config')

# ── 2. Also get imperatively installed packages ──────────────
try:
    r = subprocess.run(['nix-env', '-q', '--json'],
                       capture_output=True, text=True, timeout=15)
    if r.returncode == 0 and r.stdout.strip() and r.stdout.strip() != '{}':
        d = json.loads(r.stdout)
        for k, v in d.items():
            name = v.get('name', k)
            ver  = v.get('version', '')
            desc = (v.get('meta') or {}).get('description', '')[:60]
            results[name] = (ver, desc)
except:
    pass

# ── Write output ─────────────────────────────────────────────
with open(result_file, 'w') as f:
    for name, (ver, desc) in sorted(results.items(), key=lambda x: x[0].lower()):
        f.write(f'{name}\t{ver}\t{desc}\n')
PYEOF
  BG_PID=$!
}

finish_load_installed(){
  INST_LIST=()
  if [[ -f "$RESULT_FILE" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && INST_LIST+=("$line")
    done < "$RESULT_FILE"
  fi
  INST_SEL=0; INST_SCR=0
  if [[ ${#INST_LIST[@]} -eq 0 ]]; then
    log_op "⚠ No packages found — trying to diagnose..."
    # Show what files exist
    local f
    for f in /etc/nixos/configuration.nix /etc/nixos/flake.nix \
              "$HOME/.config/home-manager/flake.nix" \
              "$HOME/.config/nixos/flake.nix"; do
      [[ -f "$f" ]] && log_op "  found: $f"
    done
    # Check if configuration.nix has a packages block
    if [[ -f /etc/nixos/configuration.nix ]]; then
      if grep -qE '(environment\.systemPackages|home\.packages)' /etc/nixos/configuration.nix 2>/dev/null; then
        log_op "  has systemPackages block — parsing issue"
        # Show first match for debugging
        local ctx
        ctx=$(grep -n 'systemPackages' /etc/nixos/configuration.nix 2>/dev/null | head -3 || true)
        log_op "  $ctx"
      else
        log_op "  no systemPackages found in configuration.nix"
      fi
    fi
    STATUS_MSG="No packages found — see log for details"
    STATUS_COLOR="$C_YELLOW"
  else
    log_op "✓ Loaded ${#INST_LIST[@]} packages"
    STATUS_MSG="$(mode_label)  ·  ${#INST_LIST[@]} packages"
    STATUS_COLOR="$C_GREEN"
  fi
}

do_search(){
  local q="$1"
  [[ -z "$q" ]] && return
  bg_start "Searching '$q'"
  log_op "… Searching nixpkgs for '${q}'…"
  local err_file="${TMPDIR_NIXPKG}/search_err"
  rm -f "$err_file" "$RESULT_FILE"
  (
    search_pkgs "$q" > "$RESULT_FILE" 2>"$err_file"
    echo "EXIT:$?" >> "$RESULT_FILE"
  ) &
  BG_PID=$!
}

finish_search(){
  local err_file="${TMPDIR_NIXPKG}/search_err"
  SRCH_LIST=()
  local exit_code=0

  if [[ -f "$RESULT_FILE" ]]; then
    while IFS= read -r line; do
      if [[ "$line" == EXIT:* ]]; then
        exit_code="${line#EXIT:}"
      elif [[ -n "$line" ]]; then
        SRCH_LIST+=("$line")
      fi
    done < "$RESULT_FILE"
  fi
  SRCH_SEL=0; SRCH_SCR=0

  # Always show stderr in log if present
  if [[ -f "$err_file" && -s "$err_file" ]]; then
    local err_content
    err_content=$(cat "$err_file")
    if echo "$err_content" | grep -qi "experimental\|disabled\|unknown flag\|error: flake"; then
      log_op "✗ nix search requires experimental features"
      log_op "  Run this to fix:"
      log_op "  echo 'experimental-features = nix-command flakes'"
      log_op "  | sudo tee -a /etc/nix/nix.conf"
      log_op "  sudo systemctl restart nix-daemon"
      STATUS_MSG="Search needs experimental features — see log"
      STATUS_COLOR="$C_RED"
    else
      log_op "✗ Search error (exit ${exit_code}):"
      while IFS= read -r l; do
        [[ -n "$l" ]] && log_op "  ${l:0:80}"
      done <<< "$err_content"
      STATUS_MSG="Search failed (exit ${exit_code})"
      STATUS_COLOR="$C_RED"
    fi
    return
  fi

  if [[ ${#SRCH_LIST[@]} -eq 0 ]]; then
    if [[ "$exit_code" -ne 0 ]]; then
      log_op "✗ nix search failed (exit ${exit_code}) — no output"
      log_op "  Possible causes:"
      log_op "  1. experimental-features not set in /etc/nix/nix.conf"
      log_op "  2. No internet / nixpkgs cache not available"
      log_op "  3. First run may need: nix flake update"
      STATUS_MSG="Search failed — check log"
      STATUS_COLOR="$C_RED"
    else
      log_op "  No results for '${SEARCH_QUERY}'"
      STATUS_MSG="No results for '${SEARCH_QUERY}'"
      STATUS_COLOR="$C_YELLOW"
    fi
  else
    log_op "✓ Found ${#SRCH_LIST[@]} results for '${SEARCH_QUERY}'"
    STATUS_MSG="${#SRCH_LIST[@]} results for '${SEARCH_QUERY}'"
    STATUS_COLOR="$C_ACCENT"
  fi
}

do_install(){
  local name=""
  if [[ $FOCUS -eq 1 && ${#SRCH_LIST[@]} -gt 0 ]]; then
    IFS=$'\t' read -r name _ _ <<< "${SRCH_LIST[$SRCH_SEL]}"
  elif [[ $FOCUS -eq 0 && ${#INST_LIST[@]} -gt 0 ]]; then
    IFS=$'\t' read -r name _ _ <<< "${INST_LIST[$INST_SEL]}"
  fi
  [[ -z "$name" ]] && { STATUS_MSG="No package selected"; STATUS_COLOR="$C_YELLOW"; return; }

  bg_start "Installing ${name}"
  log_op "… Installing ${name}…"
  (
    install_pkg "$name" > "$RESULT_FILE" 2>&1
    echo "EXIT:$?" >> "$RESULT_FILE"
  ) &
  BG_PID=$!
  PENDING_OP="install:$name"
}

do_remove(){
  local name=""
  [[ ${#INST_LIST[@]} -gt 0 ]] && IFS=$'\t' read -r name _ _ <<< "${INST_LIST[$INST_SEL]}"
  [[ -z "$name" ]] && { STATUS_MSG="Select installed package first"; STATUS_COLOR="$C_YELLOW"; return; }

  bg_start "Removing ${name}"
  log_op "… Removing ${name}…"
  (
    remove_pkg "$name" > "$RESULT_FILE" 2>&1
    echo "EXIT:$?" >> "$RESULT_FILE"
  ) &
  BG_PID=$!
  PENDING_OP="remove:$name"
}

PENDING_OP=""

finish_op(){
  local out rc=0
  out=$(cat "$RESULT_FILE" 2>/dev/null || true)
  local exit_line
  exit_line=$(grep "^EXIT:" "$RESULT_FILE" 2>/dev/null | tail -1)
  [[ -n "$exit_line" ]] && rc=${exit_line#EXIT:}

  local op_name="${PENDING_OP%%:*}"
  local pkg_name="${PENDING_OP##*:}"
  PENDING_OP=""

  # log output lines (trim)
  while IFS= read -r l; do
    [[ "$l" =~ ^EXIT: ]] && continue
    [[ -n "$l" ]] && log_op "  $l"
  done <<< "$out"

  if [[ "$rc" -eq 0 ]]; then
    log_op "✓ ${op_name^} of '${pkg_name}' succeeded"
    STATUS_MSG="${op_name^} successful: ${pkg_name}"; STATUS_COLOR="$C_GREEN"
  else
    log_op "✗ ${op_name^} of '${pkg_name}' failed (exit ${rc})"
    STATUS_MSG="${op_name^} FAILED"; STATUS_COLOR="$C_RED"
  fi
  load_installed
}

# ─────────────────────────────────────────────────────────────
# Input handling (non-blocking read)
# ─────────────────────────────────────────────────────────────
read_key(){
  local key=""
  IFS= read -r -s -t 0.05 -n 1 key 2>/dev/null || true
  if [[ "$key" == $'\x1b' ]]; then
    local seq=""
    IFS= read -r -s -t 0.05 -n 2 seq 2>/dev/null || true
    key="${key}${seq}"
  fi
  printf '%s' "$key"
}

handle_search_input(){
  local key="$1"
  case "$key" in
    $'\x1b'|$'\x1b[')   # ESC — exit input mode, keep query
      SEARCH_MODE=0
      ;;
    $'\t')               # Tab — exit input + switch panel
      SEARCH_MODE=0
      FOCUS=$(( (FOCUS + 1) % 3 ))
      ;;
    $'\n'|$'\r')         # Enter — run search
      SEARCH_MODE=0
      if [[ -n "$SEARCH_QUERY" ]]; then
        do_search "$SEARCH_QUERY"
      fi
      ;;
    $'\x7f'|$'\b')       # backspace
      SEARCH_QUERY="${SEARCH_QUERY%?}"
      ;;
    *)
      if [[ ${#key} -eq 1 && "$key" =~ [[:print:]] ]]; then
        SEARCH_QUERY+="$key"
      fi
      ;;
  esac
}

handle_key(){
  local key="$1"

  if [[ $SEARCH_MODE -eq 1 ]]; then
    handle_search_input "$key"
    return
  fi

  case "$key" in
    q|Q) return 1 ;;
    $'\t')
      FOCUS=$(( (FOCUS + 1) % 3 ))
      ;;
    $'\x1b[A'|k)  nav_up ;;
    $'\x1b[B'|j)  nav_down ;;
    g)  go_top ;;
    G)  go_bottom ;;
    /)
      FOCUS=1
      SEARCH_MODE=1
      SEARCH_QUERY=""
      SRCH_LIST=()
      ;;
    r|R)
      load_installed
      log_op "… Reloading package list…"
      ;;
    i|I)
      [[ $LOADING -eq 0 ]] && do_install
      ;;
    d|D)
      [[ $LOADING -eq 0 && $FOCUS -eq 0 ]] && do_remove
      ;;
    $'\x1b[5'*)  # PgUp
      for _ in $(seq 1 5); do nav_up; done ;;
    $'\x1b[6'*)  # PgDn
      for _ in $(seq 1 5); do nav_down; done ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────
# Pre-flight checks  (runs BEFORE TUI, in normal terminal)
# ─────────────────────────────────────────────────────────────
preflight(){
  local ok=1

  _banner(){
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║        nixpkg — first-run setup              ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo ""
  }

  # ── nix itself ──────────────────────────────────────────────
  if ! command -v nix &>/dev/null && ! command -v nix-env &>/dev/null; then
    echo "✗ nix not found. Is NixOS installed?"
    exit 1
  fi

  # ── bash version ────────────────────────────────────────────
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "✗ bash ≥4 required (you have $BASH_VERSION)"
    exit 1
  fi

  # ── python3 ─────────────────────────────────────────────────
  if ! command -v python3 &>/dev/null; then
    _banner
    echo "  ✗ python3 not found (needed to parse config files)"
    echo ""
    printf "  Install now with nix-env? [Y/n] "
    local ans; read -r ans
    if [[ ! "$ans" =~ ^[nN]$ ]]; then
      echo "  Installing python3..."
      nix-env -iA nixpkgs.python3 && echo "  ✓ python3 installed" \
        || { echo "  ✗ Failed. Add to your config: environment.systemPackages = with pkgs; [ python3 ];"; exit 1; }
    else
      echo "  ✗ python3 is required. Exiting."
      exit 1
    fi
  fi

  # ── tput / ncurses ──────────────────────────────────────────
  if ! command -v tput &>/dev/null; then
    _banner
    echo "  ✗ tput not found (ncurses — needed for TUI drawing)"
    echo ""
    printf "  Install now with nix-env? [Y/n] "
    local ans; read -r ans
    if [[ ! "$ans" =~ ^[nN]$ ]]; then
      echo "  Installing ncurses..."
      nix-env -iA nixpkgs.ncurses && echo "  ✓ ncurses installed" \
        || { echo "  ✗ Failed. Add to config: environment.systemPackages = with pkgs; [ ncurses ];"; exit 1; }
    else
      echo "  ✗ tput is required. Exiting."
      exit 1
    fi
  fi

  # ── nix experimental-features: nix-command + flakes ─────────
  # (needed for: nix search nixpkgs ...)
  local has_nix_cmd=0 has_flakes=0
  if command -v nix &>/dev/null; then
    nix show-config 2>/dev/null | grep -q "nix-command" && has_nix_cmd=1
    nix show-config 2>/dev/null | grep -q "flakes"      && has_flakes=1
    # also check conf files directly in case daemon not restarted yet
    for f in /etc/nix/nix.conf "$HOME/.config/nix/nix.conf"; do
      [[ -f "$f" ]] || continue
      grep -qs "nix-command" "$f" && has_nix_cmd=1
      grep -qs "flakes"      "$f" && has_flakes=1
    done
  fi

  if [[ $has_nix_cmd -eq 0 || $has_flakes -eq 0 ]]; then
    _banner
    echo "  nixpkg needs nix experimental features to search packages:"
    [[ $has_nix_cmd -eq 0 ]] && echo "    ✗ nix-command"
    [[ $has_flakes -eq 0 ]]  && echo "    ✗ flakes"
    echo ""
    echo "  This adds one line to /etc/nix/nix.conf:"
    echo "    experimental-features = nix-command flakes"
    echo ""
    printf "  Enable now? (requires sudo) [Y/n] "
    local ans; read -r ans
    if [[ ! "$ans" =~ ^[nN]$ ]]; then
      local nix_conf="/etc/nix/nix.conf"
      if grep -qs "experimental-features" "$nix_conf" 2>/dev/null; then
        # line exists — patch it
        sudo sed -i 's/^\(experimental-features\s*=\s*\)/\1nix-command flakes /' "$nix_conf" \
          && echo "  ✓ Patched existing experimental-features line" \
          || { echo "  ✗ Failed to patch. Edit manually: sudo nano $nix_conf"; }
      else
        printf '\nexperimental-features = nix-command flakes\n' \
          | sudo tee -a "$nix_conf" > /dev/null \
          && echo "  ✓ Written to $nix_conf"
      fi
      echo ""
      printf "  Restart nix-daemon now? (recommended) [Y/n] "
      local ans2; read -r ans2
      if [[ ! "$ans2" =~ ^[nN]$ ]]; then
        sudo systemctl restart nix-daemon \
          && echo "  ✓ nix-daemon restarted" \
          || echo "  ⚠ Could not restart nix-daemon — try manually"
      fi
      echo ""
      echo "  Note: search (/) requires nix-command+flakes."
      echo "  Press Enter to continue…"
      read -r
    else
      echo ""
      echo "  Skipping. The search feature (/) will not work."
      echo "  Press Enter to continue anyway…"
      read -r
    fi
  fi
}

# ─────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────
main(){
  detect_mode
  preflight

  tput smcup 2>/dev/null || true
  clear_screen
  printf "%s" "$HIDE_CURSOR"
  stty -echo 2>/dev/null || true

  log_op "nixpkg started"
  log_op "Mode: $(mode_label)"
  STATUS_MSG="Starting…"; STATUS_COLOR="$C_YELLOW"

  layout
  full_redraw

  load_installed

  local tick=0
  while true; do
    # check background job
    if [[ $LOADING -eq 1 ]] && bg_wait; then
      if [[ -n "$PENDING_OP" ]]; then
        finish_op
      elif [[ "$LOADING_MSG" == "Loading"* ]]; then
        finish_load_installed
      elif [[ "$LOADING_MSG" == "Searching"* ]]; then
        finish_search
      fi
      LOADING=0
      full_redraw
    fi

    local key=""
    key=$(read_key)
    if [[ -n "$key" ]]; then
      handle_key "$key" || break
      full_redraw
    else
      # periodic partial redraw (spinner / status)
      tick=$(( tick + 1 ))
      if (( tick % 4 == 0 )); then
        draw_bottombar
        draw_topbar
      fi
    fi
  done
}

main "$@"
