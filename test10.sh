#!/usr/bin/env bash
# nixpkg — NixOS TUI package manager
# Supports: configuration.nix | flakes | imperative nix-env
set +e +u +o pipefail

ESC=$'\033'; RESET="${ESC}[0m"; BOLD="${ESC}[1m"
f(){ printf "${ESC}[38;5;${1}m"; }; b(){ printf "${ESC}[48;5;${1}m"; }
C_GREEN="$(f 114)"; C_CYAN="$(f 81)"; C_YELLOW="$(f 221)"
C_RED="$(f 203)"; C_BLUE="$(f 75)"; C_MUTED="$(f 242)"
C_WHITE="$(f 255)"; C_NIX="$(f 81)"
BG_HDR="$(b 234)"; BG_SEL="$(b 236)"; C_BORDER="$(f 238)"
CLR="${ESC}[K"; HIDE="${ESC}[?25l"; SHOW="${ESC}[?25h"
at(){ printf "${ESC}[${1};${2}H"; }
cls(){ printf "${ESC}[2J"; }

TERM_H=24; TERM_W=80
MODE=""; CONF_FILE=""
FOCUS=0; INST_LIST=(); SRCH_LIST=(); LOG=()
INST_SEL=0; INST_SCR=0; SRCH_SEL=0; SRCH_SCR=0; LOG_SCR=0
QUERY=""; TYPING=0; STATUS=""; SCOLOR=""
BG_PID=""; BG_OP=""; LOADING=0; LOADING_MSG=""
TMPD=""; RESULT=""; ERR_FILE=""
SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'); SP_I=0
LW=0; RW=0; IH=0; SH=0; RH=0
IR=2; IC=1; SR=0; SC=1; LR=2; LC=0

detect_mode(){
  if [[ -f /etc/nixos/flake.nix ]]; then
    MODE="flakes"
  elif [[ -f /etc/nixos/configuration.nix ]]; then
    MODE="configuration"; CONF_FILE="/etc/nixos/configuration.nix"
  else
    MODE="imperative"
  fi
  if [[ "$MODE" == "flakes" ]]; then
    local dirs=("/etc/nixos" "$HOME/.config/home-manager" "$HOME/.config/nixos" "$HOME/nixos")
    for d in "${dirs[@]}"; do
      [[ -d "$d" ]] || continue
      while IFS= read -r f2; do
        if grep -qE '(environment\.systemPackages|home\.packages)\s*=' "$f2" 2>/dev/null; then
          CONF_FILE="$f2"; break 2
        fi
      done < <(find "$d" -maxdepth 3 -name '*.nix' 2>/dev/null)
    done
    [[ -z "$CONF_FILE" ]] && CONF_FILE="/etc/nixos/flake.nix"
  fi
  export MODE CONF_FILE
}

mode_label(){
  case "$MODE" in
    flakes)        printf "❄ flakes  %s" "$CONF_FILE" ;;
    configuration) printf " conf.nix  %s" "$CONF_FILE" ;;
    imperative)    printf " nix-env" ;;
  esac
}

log(){ LOG+=("$1"); LOG_SCR=$(( ${#LOG[@]} > 1 ? ${#LOG[@]} - 1 : 0 )); }
status(){ STATUS="$1"; SCOLOR="$2"; }

get_size(){ TERM_H=$(tput lines); TERM_W=$(tput cols); }

trunc(){ local s="$1" n="$2"; [[ ${#s} -gt $n ]] && s="${s:0:$((n-1))}…"; printf '%s' "$s"; }

panel_box(){
  local r=$1 c=$2 h=$3 w=$4 title="$5" active=$6
  local tc; [[ $active -eq 1 ]] && tc="${C_BLUE}${BOLD}" || tc="${C_MUTED}"
  local inner=$(( w-2 ))
  at $r $c; printf "${C_BORDER}┌%s┐${RESET}" "$(printf '%*s' $inner '' | tr ' ' '─')"
  local i; for((i=1;i<h-1;i++)); do
    at $((r+i)) $c; printf "${C_BORDER}│${RESET}"
    at $((r+i)) $((c+w-1)); printf "${C_BORDER}│${RESET}"
  done
  at $((r+h-1)) $c; printf "${C_BORDER}└%s┘${RESET}" "$(printf '%*s' $inner '' | tr ' ' '─')"
  at $r $((c+2)); printf "${BG_HDR}${tc} %s ${RESET}" "$title"
}

layout(){
  get_size
  LW=$(( TERM_W*2/5 )); RW=$(( TERM_W-LW ))
  IH=$(( (TERM_H-3)/2 )); SH=$(( TERM_H-3-IH )); RH=$(( TERM_H-3 ))
  IR=2; IC=1; SR=$((2+IH)); SC=1; LR=2; LC=$((LW+1))
}

draw_installed(){
  local active=$(( FOCUS==0?1:0 ))
  panel_box $IR $IC $IH $LW "Installed" $active
  local inner=$((IH-2)) total=${#INST_LIST[@]}
  if [[ $total -eq 0 ]]; then
    at $((IR+2)) $((IC+2)); printf "${C_YELLOW}No packages found${RESET}${CLR}"; return
  fi
  local i
  for((i=0;i<inner;i++)); do
    local idx=$((INST_SCR+i)) row=$((IR+1+i))
    at $row $((IC+1)); printf "${CLR}"
    [[ $idx -ge $total ]] && continue
    local name="" ver="" desc=""
    IFS=$'\t' read -r name ver desc <<< "${INST_LIST[$idx]}"
    at $row $((IC+2))
    if [[ $idx -eq $INST_SEL && $active -eq 1 ]]; then
      printf "${BG_SEL}${C_WHITE}${BOLD}▶ %-22s %-12s${RESET}" "$(trunc "$name" 22)" "$(trunc "$ver" 12)"
    else
      printf "${C_GREEN}✓${RESET} ${C_WHITE}%-22s${RESET} ${C_MUTED}%-12s${RESET}" "$(trunc "$name" 22)" "$(trunc "$ver" 12)"
    fi
  done
  at $((IR+IH-1)) $((IC+LW-9)); printf "${C_MUTED} %d/%d ${RESET}" $((INST_SEL+1)) $total
}

draw_search(){
  local active=$(( FOCUS==1?1:0 ))
  panel_box $SR $SC $SH $LW "Search nixpkgs" $active
  at $((SR+1)) $((SC+2))
  if [[ $TYPING -eq 1 ]]; then
    printf "${C_YELLOW}${BOLD}/ %s_${RESET}${CLR}" "$QUERY"
  else
    printf "${C_MUTED}/ %s${RESET}${CLR}" "$QUERY"
  fi
  local inner=$((SH-3)) total=${#SRCH_LIST[@]}
  local i
  for((i=0;i<inner;i++)); do
    local idx=$((SRCH_SCR+i)) row=$((SR+2+i))
    at $row $((SC+1)); printf "${CLR}"
    [[ $idx -ge $total ]] && continue
    local name="" ver="" desc=""
    IFS=$'\t' read -r name ver desc <<< "${SRCH_LIST[$idx]}"
    at $row $((SC+2))
    if [[ $idx -eq $SRCH_SEL && $active -eq 1 ]]; then
      printf "${BG_SEL}${C_WHITE}${BOLD}▶ %-22s %-10s${RESET}" "$(trunc "$name" 22)" "$(trunc "$ver" 10)"
    else
      printf "  ${C_WHITE}%-22s${RESET} ${C_MUTED}%-10s${RESET}" "$(trunc "$name" 22)" "$(trunc "$ver" 10)"
    fi
  done
  [[ $total -gt 0 ]] && { at $((SR+SH-1)) $((SC+LW-9)); printf "${C_MUTED} %d/%d ${RESET}" $((SRCH_SEL+1)) $total; }
}

draw_log(){
  local active=$(( FOCUS==2?1:0 ))
  panel_box $LR $LC $RH $RW "Info / Log" $active
  local iw=$((RW-4))
  local pkg_line=""
  [[ $FOCUS -eq 0 && ${#INST_LIST[@]} -gt 0 ]] && pkg_line="${INST_LIST[$INST_SEL]}"
  [[ $FOCUS -eq 1 && ${#SRCH_LIST[@]} -gt 0 ]] && pkg_line="${SRCH_LIST[$SRCH_SEL]}"
  local log_start=$((LR+1))
  if [[ -n "$pkg_line" ]]; then
    local name="" ver="" desc=""
    IFS=$'\t' read -r name ver desc <<< "$pkg_line"
    at $((LR+1)) $((LC+2)); printf "${C_GREEN}${BOLD}%-24s${RESET} ${C_CYAN}%s${RESET}${CLR}" "$(trunc "$name" 24)" "$ver"
    at $((LR+2)) $((LC+2)); printf "${C_MUTED}%s${RESET}${CLR}" "$(trunc "${desc:-(no description)}" $iw)"
    at $((LR+3)) $((LC+1)); printf "${C_BORDER}%s${RESET}" "$(printf '%*s' $((RW-2)) '' | tr ' ' '─')"
    log_start=$((LR+4))
  else
    for r in $((LR+1)) $((LR+2)) $((LR+3)); do at $r $((LC+1)); printf "${CLR}"; done
  fi
  local log_h=$((LR+RH-1-log_start)) total=${#LOG[@]}
  local i
  for((i=0;i<=log_h;i++)); do
    local row=$((log_start+i))
    at $row $((LC+1)); printf "${CLR}"
    local idx=$((LOG_SCR+i))
    [[ $idx -ge $total ]] && continue
    local txt="${LOG[$idx]}" c="$C_MUTED"
    [[ "$txt" == *"✓"* ]] && c="$C_GREEN"
    [[ "$txt" == *"✗"* ]] && c="$C_RED"
    [[ "$txt" == *"…"* || "$txt" == *"..."* ]] && c="$C_YELLOW"
    at $row $((LC+2)); printf "%s%s${RESET}" "$c" "$(trunc "$txt" $iw)"
  done
}

draw_topbar(){
  at 1 1
  printf "${BG_HDR}${C_NIX}${BOLD} ❄  nixpkg ${RESET}${BG_HDR}${C_MUTED} $(mode_label) ${RESET}${CLR}"
}

draw_bottombar(){
  at $TERM_H 1
  if [[ $LOADING -eq 1 ]]; then
    printf "${BG_HDR}${C_YELLOW}${BOLD} %s %s ${RESET}" "${SPINNER[$SP_I]}" "$LOADING_MSG"
  else
    printf "${BG_HDR}${SCOLOR}${BOLD} %s ${RESET}" "$STATUS"
  fi
  printf "${BG_HDR}${C_MUTED} [tab]panel [j/k]↑↓ [/]search [i]install [d]remove [r]reload [q]quit${RESET}${CLR}"
}

redraw(){ draw_topbar; draw_installed; draw_search; draw_log; draw_bottombar; }

nav_up(){
  if [[ $FOCUS -eq 0 && $INST_SEL -gt 0 ]]; then
    ((INST_SEL--)); [[ $INST_SEL -lt $INST_SCR ]] && INST_SCR=$INST_SEL
  elif [[ $FOCUS -eq 1 && $SRCH_SEL -gt 0 ]]; then
    ((SRCH_SEL--)); [[ $SRCH_SEL -lt $SRCH_SCR ]] && SRCH_SCR=$SRCH_SEL
  elif [[ $FOCUS -eq 2 && $LOG_SCR -gt 0 ]]; then ((LOG_SCR--)); fi
}
nav_down(){
  if [[ $FOCUS -eq 0 ]]; then
    local m=$(( ${#INST_LIST[@]}-1 )); [[ $INST_SEL -lt $m ]] && ((INST_SEL++))
    local v=$((IH-2)); [[ $INST_SEL -ge $((INST_SCR+v)) ]] && INST_SCR=$((INST_SEL-v+1))
  elif [[ $FOCUS -eq 1 ]]; then
    local m=$(( ${#SRCH_LIST[@]}-1 )); [[ $SRCH_SEL -lt $m ]] && ((SRCH_SEL++))
    local v=$((SH-3)); [[ $SRCH_SEL -ge $((SRCH_SCR+v)) ]] && SRCH_SCR=$((SRCH_SEL-v+1))
  elif [[ $FOCUS -eq 2 ]]; then
    local m=$(( ${#LOG[@]}-1 )); [[ $LOG_SCR -lt $m ]] && ((LOG_SCR++))
  fi
}

bg_start(){ LOADING=1; LOADING_MSG="$1"; BG_OP="$2"; RESULT="$TMPD/result"; ERR_FILE="$TMPD/err"; rm -f "$RESULT" "$ERR_FILE" "$TMPD/rc"; }
bg_done(){ [[ -z "$BG_PID" ]] && { LOADING=0; return 0; }; kill -0 "$BG_PID" 2>/dev/null && return 1; wait "$BG_PID" 2>/dev/null; BG_PID=""; return 0; }

start_load(){
  bg_start "Loading packages" "load"
  python3 - "$RESULT" "$MODE" "$CONF_FILE" <<"PYEOF" &
import sys,re,subprocess,json,os
rf,mode,cf=sys.argv[1],sys.argv[2],sys.argv[3]
pkgs={}
def parse(path):
  try: content=open(path).read()
  except: return
  for m in re.finditer(r'(?:environment\.systemPackages|home\.packages)\s*=\s*(.*?)(?=\n\s*\n|\Z)',content,re.DOTALL):
    block=m.group(1)
    wm=re.search(r'with\s+pkgs\s*;\s*\[(.*?)\]',block,re.DOTALL)
    if wm:
      inner=re.sub(r'#[^\n]*','',wm.group(1))
      for n in re.findall(r'\b([a-zA-Z][a-zA-Z0-9_\-]*)\b',inner):
        if n not in ('with','pkgs','let','in','if','then','else','rec','inherit','null','true','false'):
          pkgs[n]=('','in config')
    for n in re.findall(r'\bpkgs\.([a-zA-Z0-9][a-zA-Z0-9_\-]*)',block):
      pkgs[n]=('','in config')
if mode in ('configuration','flakes') and cf and os.path.isfile(cf):
  parse(cf)
  d=os.path.dirname(cf)
  for fn in (os.listdir(d) if os.path.isdir(d) else []):
    if fn.endswith('.nix') and fn!=os.path.basename(cf): parse(os.path.join(d,fn))
try:
  r=subprocess.run(['nix-env','-q','--json'],capture_output=True,text=True,timeout=15)
  if r.returncode==0 and r.stdout.strip() not in ('','{}'):
    for k,v in json.loads(r.stdout).items():
      n=v.get('name',k); pkgs[n]=(v.get('version',''),(v.get('meta') or {}).get('description','')[:60])
except: pass
open(rf,'w').writelines(f'{n}\t{ver}\t{desc}\n' for n,(ver,desc) in sorted(pkgs.items(),key=lambda x:x[0].lower()))
PYEOF
  BG_PID=$!
}

finish_load(){
  INST_LIST=()
  [[ -f "$RESULT" ]] && while IFS= read -r line; do [[ -n "$line" ]] && INST_LIST+=("$line"); done < "$RESULT"
  INST_SEL=0; INST_SCR=0
  if [[ ${#INST_LIST[@]} -eq 0 ]]; then
    log "⚠ No packages found"; log "  Config: ${CONF_FILE:-not found}"; status "No packages found" "$C_YELLOW"
  else
    log "✓ Loaded ${#INST_LIST[@]} packages"; status "$(mode_label)  ·  ${#INST_LIST[@]} packages" "$C_GREEN"
  fi
}

start_search(){
  local q="$1"; [[ -z "$q" ]] && return
  bg_start "Searching '${q}'" "search"
  log "… nix search nixpkgs '${q}'"
  ( timeout 60 nix search nixpkgs "$q" --json >"$RESULT" 2>"$ERR_FILE"; echo $? >"$TMPD/rc" ) &
  BG_PID=$!
}

finish_search(){
  local rc=0; [[ -f "$TMPD/rc" ]] && rc=$(cat "$TMPD/rc")
  SRCH_LIST=()
  if [[ -f "$RESULT" && -s "$RESULT" ]]; then
    local parsed="$TMPD/sp"
    python3 -c "
import sys,json
try: d=json.load(open(sys.argv[1]))
except Exception as e: print(f'err:{e}',file=sys.stderr); sys.exit(1)
for k,v in list(d.items())[:150]:
  print(f\"{k.split('.')[-1]}\t{v.get('version','')}\t{v.get('description','')[:70]}\")
" "$RESULT" >"$parsed" 2>"$ERR_FILE"
    while IFS= read -r line; do [[ -n "$line" ]] && SRCH_LIST+=("$line"); done < "$parsed"
  fi
  SRCH_SEL=0; SRCH_SCR=0
  if [[ ${#SRCH_LIST[@]} -gt 0 ]]; then
    log "✓ Found ${#SRCH_LIST[@]} results for '${QUERY}'"
    status "${#SRCH_LIST[@]} results" "$C_BLUE"
  elif [[ -f "$ERR_FILE" && -s "$ERR_FILE" ]]; then
    local err; err=$(head -2 "$ERR_FILE")
    if echo "$err" | grep -qi "experimental\|flake\|unknown"; then
      log "✗ nix search needs experimental features"
      log "  echo 'experimental-features = nix-command flakes'"
      log "  | sudo tee -a /etc/nix/nix.conf"
      log "  sudo systemctl restart nix-daemon"
    else
      log "✗ Search failed (exit ${rc}):"; head -4 "$ERR_FILE" | while IFS= read -r l; do log "  $l"; done
    fi
    status "Search failed — see log" "$C_RED"
  else
    log "  No results for '${QUERY}'"; status "No results" "$C_YELLOW"
  fi
}

edit_config(){
  # edit_config add|remove <pkg> <file>  — stdout goes to caller
  local action="$1" pkg="$2" file="$3"
  cp "$file" "${file}.nixpkg.bak" 2>/dev/null
  python3 - "$action" "$pkg" "$file" <<"PYEOF"
import sys,re
action,pkg,path=sys.argv[1],sys.argv[2],sys.argv[3]
content=open(path).read()
pats=[
  (re.compile(r'(environment\.systemPackages\s*=\s*with\s+pkgs\s*;\s*\[)(.*?)(\];)',re.DOTALL),True),
  (re.compile(r'(environment\.systemPackages\s*=\s*\[)(.*?)(\];)',re.DOTALL),False),
  (re.compile(r'(home\.packages\s*=\s*with\s+pkgs\s*;\s*\[)(.*?)(\];)',re.DOTALL),True),
  (re.compile(r'(home\.packages\s*=\s*\[)(.*?)(\];)',re.DOTALL),False),
]
m=None; use_with=False
for pat,uw in pats:
  m=pat.search(content)
  if m: use_with=uw; break
if not m: print(f"ERROR: no packages list in {path}",file=sys.stderr); sys.exit(1)
inner=m.group(2)
entry=pkg if use_with else f"pkgs.{pkg}"
if action=='add':
  if re.search(rf'\b{re.escape(entry)}\b',inner): print(f"'{entry}' already present"); sys.exit(0)
  indent="  "
  for line in inner.splitlines():
    s=line.lstrip()
    if s and not s.startswith('#'): indent=line[:len(line)-len(s)]; break
  new_inner=inner.rstrip('\n')+f"\n{indent}{entry}\n"
  new_content=content[:m.start()]+m.group(1)+new_inner+m.group(3)+content[m.end():]
  print(f"Added '{entry}' to {path}")
elif action=='remove':
  new_lines=[]; removed=0
  for line in (m.group(1)+inner+m.group(3)).splitlines(keepends=True):
    if re.search(rf'^\s*{re.escape(pkg)}\s*(#.*)?$',line) or re.search(rf'\bpkgs\.{re.escape(pkg)}\b',line):
      removed+=1
    else: new_lines.append(line)
  if removed==0: print(f"ERROR: '{pkg}' not found",file=sys.stderr); sys.exit(1)
  new_content=content[:m.start()]+''.join(new_lines)+content[m.end():]
  print(f"Removed '{pkg}' from {path}")
open(path,'w').write(new_content)
PYEOF
}

do_rebuild(){
  local file="$1"
  if grep -q 'home\.packages' "$file" 2>/dev/null && command -v home-manager &>/dev/null; then
    echo "Running: home-manager switch"; home-manager switch 2>&1 | tail -8
  else
    echo "Running: sudo nixos-rebuild switch"; sudo nixos-rebuild switch 2>&1 | tail -8
  fi
}

start_install(){
  local name=""
  [[ $FOCUS -eq 1 && ${#SRCH_LIST[@]} -gt 0 ]] && IFS=$'\t' read -r name _ _ <<< "${SRCH_LIST[$SRCH_SEL]}"
  [[ $FOCUS -eq 0 && ${#INST_LIST[@]} -gt 0 ]] && IFS=$'\t' read -r name _ _ <<< "${INST_LIST[$INST_SEL]}"
  [[ -z "$name" ]] && { status "No package selected" "$C_YELLOW"; return; }
  bg_start "Installing ${name}" "install:${name}"
  log "… Installing '${name}'…"
  local cf="$CONF_FILE" mode="$MODE" res="$RESULT"
  ( rc=0
    case "$mode" in
      configuration|flakes)
        out=$(edit_config add "$name" "$cf" 2>&1); rc=$?; echo "$out"
        [[ $rc -eq 0 ]] && { do_rebuild "$cf" 2>&1; rc=$?; }
        ;;
      imperative) nix-env -iA "nixpkgs.${name}" 2>&1; rc=$? ;;
    esac
    echo "EXIT:${rc}"
  ) >"$res" 2>&1 &
  BG_PID=$!
}

start_remove(){
  [[ $FOCUS -ne 0 || ${#INST_LIST[@]} -eq 0 ]] && { status "Select package in Installed panel first" "$C_YELLOW"; return; }
  local name=""; IFS=$'\t' read -r name _ _ <<< "${INST_LIST[$INST_SEL]}"
  [[ -z "$name" ]] && return
  bg_start "Removing ${name}" "remove:${name}"
  log "… Removing '${name}'…"
  local cf="$CONF_FILE" mode="$MODE" res="$RESULT"
  ( rc=0
    case "$mode" in
      configuration|flakes)
        out=$(edit_config remove "$name" "$cf" 2>&1); rc=$?; echo "$out"
        [[ $rc -eq 0 ]] && { do_rebuild "$cf" 2>&1; rc=$?; }
        ;;
      imperative) nix-env -e "$name" 2>&1; rc=$? ;;
    esac
    echo "EXIT:${rc}"
  ) >"$res" 2>&1 &
  BG_PID=$!
}

finish_op(){
  local rc=0
  [[ -f "$RESULT" ]] && { local el; el=$(grep "^EXIT:" "$RESULT" | tail -1); [[ -n "$el" ]] && rc="${el#EXIT:}"; }
  [[ -f "$RESULT" ]] && while IFS= read -r l; do [[ "$l" == EXIT:* ]] && continue; [[ -n "$l" ]] && log "  $l"; done < "$RESULT"
  local op="${BG_OP%%:*}" pkg="${BG_OP##*:}"
  if [[ "$rc" -eq 0 ]]; then
    log "✓ ${op^} of '${pkg}' succeeded"; status "${op^} OK: ${pkg}" "$C_GREEN"
    start_load
  else
    log "✗ ${op^} of '${pkg}' FAILED (exit ${rc})"; status "${op^} FAILED" "$C_RED"; LOADING=0
  fi
}

preflight(){
  local has=0
  nix show-config 2>/dev/null | grep -q "experimental-features.*nix-command" && has=1
  grep -qs "experimental-features.*nix-command" /etc/nix/nix.conf ~/.config/nix/nix.conf 2>/dev/null && has=1
  [[ $has -eq 1 ]] && return
  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║    nixpkg — first run setup needed           ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo "  Search requires: experimental-features = nix-command flakes"
  echo ""
  printf "  Add to /etc/nix/nix.conf now? [Y/n] "
  local ans; read -r ans
  if [[ ! "$ans" =~ ^[nN]$ ]]; then
    if grep -qs "experimental-features" /etc/nix/nix.conf 2>/dev/null; then
      echo "  nix.conf already has experimental-features line — add 'nix-command flakes' manually"
    else
      printf '\nexperimental-features = nix-command flakes\n' | sudo tee -a /etc/nix/nix.conf >/dev/null
      echo "  ✓ Written to /etc/nix/nix.conf"
      printf "  Restart nix-daemon? [Y/n] "; local a2; read -r a2
      [[ ! "$a2" =~ ^[nN]$ ]] && sudo systemctl restart nix-daemon && echo "  ✓ Restarted"
    fi
  fi
  echo "  Press Enter to continue…"; read -r
}

read_key(){
  local k=""
  IFS= read -r -s -t 0.05 -n 1 k 2>/dev/null || true
  if [[ "$k" == $'\x1b' ]]; then
    local s=""; IFS= read -r -s -t 0.05 -n 3 s 2>/dev/null || true; k="${k}${s}"
  fi
  printf '%s' "$k"
}

handle_typing(){
  local k="$1"
  case "$k" in
    $'\t')       TYPING=0; FOCUS=$(( (FOCUS+1)%3 )) ;;
    $'\x1b'*)    TYPING=0 ;;
    $'\n'|$'\r') TYPING=0; [[ -n "$QUERY" ]] && { SRCH_LIST=(); start_search "$QUERY"; } ;;
    $'\x7f'|$'\b') QUERY="${QUERY%?}" ;;
    *) [[ ${#k} -eq 1 && "$k" =~ [[:print:]] ]] && QUERY+="$k" ;;
  esac
}

handle_key(){
  local k="$1"
  [[ $TYPING -eq 1 ]] && { handle_typing "$k"; return 0; }
  case "$k" in
    q|Q) return 1 ;;
    $'\t') FOCUS=$(( (FOCUS+1)%3 )) ;;
    $'\x1b[A'|k) nav_up ;;
    $'\x1b[B'|j) nav_down ;;
    g) INST_SEL=0; INST_SCR=0; SRCH_SEL=0; SRCH_SCR=0 ;;
    G) [[ ${#INST_LIST[@]} -gt 0 ]] && INST_SEL=$(( ${#INST_LIST[@]}-1 ))
       [[ ${#SRCH_LIST[@]} -gt 0 ]] && SRCH_SEL=$(( ${#SRCH_LIST[@]}-1 )) ;;
    /) FOCUS=1; TYPING=1; QUERY="" ;;
    i|I) [[ $LOADING -eq 0 ]] && start_install ;;
    d|D) [[ $LOADING -eq 0 ]] && start_remove ;;
    r|R) log "… reloading…"; start_load ;;
    $'\x1b[5'*) for _ in 1 2 3 4 5; do nav_up; done ;;
    $'\x1b[6'*) for _ in 1 2 3 4 5; do nav_down; done ;;
  esac
  return 0
}

cleanup(){
  printf '%s' "$SHOW"; tput rmcup 2>/dev/null || true
  stty echo 2>/dev/null || true
  [[ -n "$BG_PID" ]] && kill "$BG_PID" 2>/dev/null || true
  [[ -n "$TMPD" ]] && rm -rf "$TMPD"
}
trap cleanup EXIT INT TERM

main(){
  detect_mode; preflight
  TMPD=$(mktemp -d)
  tput smcup 2>/dev/null || true; cls
  printf '%s' "$HIDE"; stty -echo 2>/dev/null || true
  layout
  log "nixpkg — $(mode_label)"
  status "Loading…" "$C_YELLOW"
  redraw; start_load
  local tick=0
  while true; do
    if [[ $LOADING -eq 1 ]] && bg_done; then
      LOADING=0
      case "$BG_OP" in
        load) finish_load ;;
        search) finish_search ;;
        install:*|remove:*) finish_op ;;
      esac
      redraw
    fi
    local k=""; k=$(read_key)
    if [[ -n "$k" ]]; then handle_key "$k" || break; redraw
    else
      tick=$(( tick+1 ))
      if (( tick%2==0 )) && [[ $LOADING -eq 1 ]]; then
        SP_I=$(( (SP_I+1)%10 )); draw_bottombar
      fi
    fi
  done
}

main "$@"
