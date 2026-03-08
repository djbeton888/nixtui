#!/usr/bin/env python3
"""
nixpkg — NixOS TUI package manager
Python rewrite: clean, no bash subshell inheritance issues
Deps: Python 3.6+ stdlib only (curses)
"""

import curses
import subprocess
import threading
import json
import os
import re
import sys
import time
import shutil
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

# ─────────────────────────────────────────────────────────────
# Data
# ─────────────────────────────────────────────────────────────
@dataclass
class Package:
    name: str
    version: str = ""
    description: str = ""
    source: str = ""   # "in config" | "nix-env" | ""

@dataclass
class AppState:
    mode: str = ""          # configuration | flakes | imperative
    conf_file: str = ""

    focus: int = 0          # 0=installed 1=search 2=log
    inst_list: List[Package] = field(default_factory=list)
    srch_list: List[Package] = field(default_factory=list)
    log_lines: List[Tuple[str,str]] = field(default_factory=list)  # (text, color_key)

    inst_sel: int = 0;  inst_scr: int = 0
    srch_sel: int = 0;  srch_scr: int = 0
    log_scr:  int = 0

    query: str = "";    typing: bool = False
    status: str = "";   status_color: str = "green"

    loading: bool = False
    loading_msg: str = ""
    spinner_i: int = 0

    bg_thread: Optional[threading.Thread] = None
    bg_result: Optional[dict] = None   # set by thread when done
    bg_lock: threading.Lock = field(default_factory=threading.Lock)

SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

# ─────────────────────────────────────────────────────────────
# NixOS config detection
# ─────────────────────────────────────────────────────────────
def detect_mode(state: AppState):
    if Path("/etc/nixos/flake.nix").exists():
        state.mode = "flakes"
        # Find file with systemPackages
        search_dirs = [
            "/etc/nixos",
            str(Path.home() / ".config/home-manager"),
            str(Path.home() / ".config/nixos"),
            str(Path.home() / "nixos"),
        ]
        for d in search_dirs:
            if not Path(d).is_dir():
                continue
            for nix in Path(d).rglob("*.nix"):
                try:
                    if re.search(r'(environment\.systemPackages|home\.packages)\s*=', nix.read_text()):
                        state.conf_file = str(nix)
                        return
                except:
                    pass
        state.conf_file = "/etc/nixos/flake.nix"
    elif Path("/etc/nixos/configuration.nix").exists():
        state.mode = "configuration"
        state.conf_file = "/etc/nixos/configuration.nix"
    else:
        state.mode = "imperative"

def mode_label(state: AppState) -> str:
    if state.mode == "flakes":
        return f"❄ flakes  {state.conf_file}"
    elif state.mode == "configuration":
        return f"conf.nix  {state.conf_file}"
    return "nix-env (imperative)"

# ─────────────────────────────────────────────────────────────
# Config file editing  (the key thing — runs in main thread or bg thread, pure Python)
# ─────────────────────────────────────────────────────────────
def parse_installed(conf_file: str) -> List[Package]:
    """Parse packages from .nix config files."""
    pkgs: dict = {}

    def parse_file(path: str):
        try:
            content = open(path).read()
        except:
            return
        # Find all systemPackages / home.packages blocks
        for m in re.finditer(
            r'(?:environment\.systemPackages|home\.packages)\s*=\s*(.*?)(?=\n\s*\n|\Z)',
            content, re.DOTALL
        ):
            block = m.group(1)
            # Style A: with pkgs; [ foo bar ]
            wm = re.search(r'with\s+pkgs\s*;\s*\[(.*?)\]', block, re.DOTALL)
            if wm:
                inner = re.sub(r'#[^\n]*', '', wm.group(1))
                skip = {'with','pkgs','let','in','if','then','else',
                        'rec','inherit','null','true','false'}
                for name in re.findall(r'\b([a-zA-Z][a-zA-Z0-9_\-\.]*)\b', inner):
                    if name not in skip:
                        pkgs[name] = Package(name=name, source="in config")
            # Style B: [ pkgs.foo pkgs.bar ]
            for name in re.findall(r'\bpkgs\.([a-zA-Z0-9][a-zA-Z0-9_\-\.]*)', block):
                pkgs[name] = Package(name=name, source="in config")

    if conf_file and Path(conf_file).is_file():
        parse_file(conf_file)
        d = Path(conf_file).parent
        for f in d.glob("*.nix"):
            if str(f) != conf_file:
                parse_file(str(f))

    return sorted(pkgs.values(), key=lambda p: p.name.lower())


def edit_nix_config(action: str, pkg_name: str, conf_file: str) -> str:
    """
    Add or remove a package from the nix config file.
    Returns '' on success, error message on failure.
    """
    try:
        content = open(conf_file).read()
    except Exception as e:
        return f"Cannot read {conf_file}: {e}"

    # Find the right block — prefer environment.systemPackages with pkgs; style
    patterns = [
        (re.compile(r'(environment\.systemPackages\s*=\s*with\s+pkgs\s*;\s*\[)(.*?)(\];)', re.DOTALL), True),
        (re.compile(r'(environment\.systemPackages\s*=\s*\[)(.*?)(\];)', re.DOTALL), False),
        (re.compile(r'(home\.packages\s*=\s*with\s+pkgs\s*;\s*\[)(.*?)(\];)', re.DOTALL), True),
        (re.compile(r'(home\.packages\s*=\s*\[)(.*?)(\];)', re.DOTALL), False),
    ]

    m = None
    use_with = False
    for pat, uw in patterns:
        m = pat.search(content)
        if m:
            use_with = uw
            break

    if not m:
        return f"No packages list found in {conf_file}"

    entry = pkg_name if use_with else f"pkgs.{pkg_name}"
    inner = m.group(2)

    if action == "add":
        if re.search(rf'\b{re.escape(entry)}\b', inner):
            return f"'{entry}' already present"
        # Detect indent from existing entries
        indent = "  "
        for line in inner.splitlines():
            s = line.lstrip()
            if s and not s.startswith('#'):
                indent = line[:len(line) - len(s)]
                break
        new_inner = inner.rstrip('\n') + f"\n{indent}{entry}\n"
        new_content = content[:m.start()] + m.group(1) + new_inner + m.group(3) + content[m.end():]

    elif action == "remove":
        new_inner_lines = []
        removed = 0
        for line in inner.splitlines(keepends=True):
            if (re.search(rf'^\s*{re.escape(pkg_name)}\s*(#.*)?$', line) or
                    re.search(rf'\bpkgs\.{re.escape(pkg_name)}\b', line)):
                removed += 1
            else:
                new_inner_lines.append(line)
        if removed == 0:
            return f"'{pkg_name}' not found in packages list in {conf_file}"
        new_inner = ''.join(new_inner_lines)
        new_content = content[:m.start()] + m.group(1) + new_inner + m.group(3) + content[m.end():]
    else:
        return f"Unknown action: {action}"

    # Backup + write
    try:
        open(conf_file + '.bak', 'w').write(content)
        open(conf_file, 'w').write(new_content)
    except Exception as e:
        return f"Write failed: {e}"

    return ""   # success


def run_rebuild(conf_file: str, log_fn) -> int:
    """Run nixos-rebuild or home-manager switch. Returns exit code."""
    try:
        content = open(conf_file).read()
        use_hm = ('home.packages' in content and shutil.which('home-manager'))
    except:
        use_hm = False

    if use_hm:
        cmd = ['home-manager', 'switch']
        log_fn("  Running: home-manager switch")
    else:
        cmd = ['sudo', 'nixos-rebuild', 'switch']
        log_fn("  Running: sudo nixos-rebuild switch")

    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    lines = []
    for line in proc.stdout:
        lines.append(line.rstrip())
    proc.wait()
    # Show last 8 lines in log
    for l in lines[-8:]:
        log_fn(f"  {l}")
    return proc.returncode

# ─────────────────────────────────────────────────────────────
# Local package index (like nix-search-tv: build once, search instantly)
# ─────────────────────────────────────────────────────────────
CACHE_DIR = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'nixpkg'
INDEX_FILE = CACHE_DIR / 'index.tsv'

def index_is_stale() -> bool:
    if not INDEX_FILE.exists():
        return True
    age = time.time() - INDEX_FILE.stat().st_mtime
    return age > 86400  # 24h

def build_index(log_fn) -> bool:
    """Build local package index from nix-env -qa --json. Returns True on success."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    log_fn("  Running: nix-env -qa --json  (first run, ~30s)")
    try:
        r = subprocess.run(
            ['nix-env', '-qa', '--json'],
            capture_output=True, text=True, timeout=180
        )
        if r.returncode == 0 and r.stdout.strip():
            data = json.loads(r.stdout)
            with open(INDEX_FILE, 'w') as f:
                for attr, v in sorted(data.items(), key=lambda x: x[0].lower()):
                    name = attr.split('.')[-1]
                    ver  = v.get('version', '')
                    desc = (v.get('meta') or {}).get('description', '')[:80].replace('\n', ' ')
                    f.write(f"{name}\t{ver}\t{desc}\n")
            log_fn(f"  Index built: {len(data)} packages → {INDEX_FILE}")
            return True
    except subprocess.TimeoutExpired:
        log_fn("  ERROR: nix-env -qa timed out (180s)")
        return False
    except Exception as e:
        log_fn(f"  ERROR building index: {e}")
        return False

    # Fallback: plain nix-env -qa
    log_fn("  Fallback: nix-env -qa (plain)")
    try:
        r2 = subprocess.run(['nix-env', '-qa'], capture_output=True, text=True, timeout=180)
        if r2.returncode != 0:
            log_fn(f"  ERROR: {r2.stderr[:100]}")
            return False
        with open(INDEX_FILE, 'w') as f:
            for line in r2.stdout.splitlines():
                line = line.strip()
                if not line: continue

                mm = re.match(r'^(.*?)-(\d[\w\.\-]*)$', line)
                name, ver = (mm.group(1), mm.group(2)) if mm else (line, '')
                f.write(f"{name}\t{ver}\t\n")
        return True
    except Exception as e:
        log_fn(f"  ERROR: {e}")
        return False


def search_index(query: str) -> List[Package]:
    """Search local index file. Instant."""
    if not INDEX_FILE.exists():
        return []
    terms = query.lower().split()
    results = []
    with open(INDEX_FILE) as f:
        for line in f:
            if all(t in line.lower() for t in terms):
                parts = line.rstrip('\n').split('\t', 2)
                name = parts[0] if parts else ''
                ver  = parts[1] if len(parts) > 1 else ''
                desc = parts[2] if len(parts) > 2 else ''
                results.append(Package(name=name, version=ver, description=desc))

    def score(p):
        n = p.name.lower()
        if n == query.lower(): return 0
        if n.startswith(query.lower()): return 1
        if query.lower() in n: return 2
        return 3

    results.sort(key=score)
    return results[:200]

# ─────────────────────────────────────────────────────────────
# Background thread runner
# ─────────────────────────────────────────────────────────────
def run_in_bg(state: AppState, op: str, fn):
    """Run fn() in background thread, store result in state.bg_result."""
    def worker():
        result = fn()
        with state.bg_lock:
            state.bg_result = {'op': op, **result}

    state.bg_result = None
    state.bg_thread = threading.Thread(target=worker, daemon=True)
    state.bg_thread.start()

# ─────────────────────────────────────────────────────────────
# Operations (called from main loop, run in bg thread)
# ─────────────────────────────────────────────────────────────
def op_load_installed(state: AppState):
    state.loading = True
    state.loading_msg = "Loading packages…"
    log_lines_buf = []

    def work():
        pkgs = parse_installed(state.conf_file)
        # Also get nix-env installed
        try:
            r = subprocess.run(['nix-env', '-q', '--json'],
                               capture_output=True, text=True, timeout=15)
            if r.returncode == 0 and r.stdout.strip() not in ('', '{}'):
                ne = json.loads(r.stdout)
                names = {p.name for p in pkgs}
                for k, v in ne.items():
                    n = v.get('name', k)
                    if n not in names:
                        pkgs.append(Package(
                            name=n,
                            version=v.get('version', ''),
                            description=(v.get('meta') or {}).get('description', '')[:60],
                            source='nix-env'
                        ))
        except:
            pass
        pkgs.sort(key=lambda p: p.name.lower())
        return {'packages': pkgs}

    run_in_bg(state, 'load', work)


def op_search(state: AppState, query: str):
    state.loading = True
    state.loading_msg = f"Searching '{query}'…"

    def work():
        logs = []
        if index_is_stale():
            logs.append(("  Building local index (first run ~30s)…", "yellow"))
            ok = build_index(lambda l: logs.append((l, "muted")))
            if not ok:
                return {'packages': [], 'logs': logs + [("✗ Index build failed", "red")]}
            logs.append(("✓ Index built", "green"))
        results = search_index(query)
        if results:
            logs.append((f"✓ {len(results)} results for '{query}'", "green"))
        else:
            logs.append((f"  No results for '{query}'", "yellow"))
        return {'packages': results, 'logs': logs}

    run_in_bg(state, 'search', work)


def op_install(state: AppState):
    pkg = _selected_pkg(state)
    if not pkg:
        state.status = "Select a package first"; state.status_color = "yellow"; return

    state.loading = True
    state.loading_msg = f"Installing {pkg.name}…"
    mode, cf = state.mode, state.conf_file
    pkg_name = pkg.name

    def work():
        logs = [(f"… Installing '{pkg_name}'…", "yellow")]
        if mode == 'imperative':
            r = subprocess.run(['nix-env', '-iA', f'nixpkgs.{pkg_name}'],
                               capture_output=True, text=True)
            ok = r.returncode == 0
            for l in (r.stdout + r.stderr).strip().splitlines()[-6:]:
                logs.append((f"  {l}", "muted"))
        else:
            err = edit_nix_config('add', pkg_name, cf)
            if err:
                return {'ok': False, 'logs': logs + [(f"✗ {err}", "red")]}
            logs.append((f"  Added '{pkg_name}' to {cf}", "green"))
            rc = run_rebuild(cf, lambda l: logs.append((l, "muted")))
            ok = (rc == 0)

        if ok:
            logs.append((f"✓ Installed '{pkg_name}'", "green"))
        else:
            logs.append((f"✗ Install failed", "red"))
        return {'ok': ok, 'logs': logs}

    run_in_bg(state, 'install', work)


def op_remove(state: AppState):
    if state.focus != 0 or not state.inst_list:
        state.status = "Switch to Installed panel first"; state.status_color = "yellow"; return

    pkg = state.inst_list[state.inst_sel]
    state.loading = True
    state.loading_msg = f"Removing {pkg.name}…"
    mode, cf = state.mode, state.conf_file
    pkg_name = pkg.name

    def work():
        logs = [(f"… Removing '{pkg_name}'…", "yellow")]
        if mode == 'imperative':
            r = subprocess.run(['nix-env', '-e', pkg_name],
                               capture_output=True, text=True)
            ok = r.returncode == 0
            for l in (r.stdout + r.stderr).strip().splitlines()[-6:]:
                logs.append((f"  {l}", "muted"))
        else:
            err = edit_nix_config('remove', pkg_name, cf)
            if err:
                return {'ok': False, 'logs': logs + [(f"✗ {err}", "red")]}
            logs.append((f"  Removed '{pkg_name}' from {cf}", "green"))
            rc = run_rebuild(cf, lambda l: logs.append((l, "muted")))
            ok = (rc == 0)

        if ok:
            logs.append((f"✓ Removed '{pkg_name}'", "green"))
        else:
            logs.append((f"✗ Remove failed", "red"))
        return {'ok': ok, 'logs': logs}

    run_in_bg(state, 'remove', work)


def _selected_pkg(state: AppState) -> Optional[Package]:
    if state.focus == 1 and state.srch_list:
        return state.srch_list[state.srch_sel]
    if state.focus == 0 and state.inst_list:
        return state.inst_list[state.inst_sel]
    return None

# ─────────────────────────────────────────────────────────────
# TUI drawing (curses)
# ─────────────────────────────────────────────────────────────
def init_colors():
    curses.start_color()
    curses.use_default_colors()
    # Use only standard 8 colors for maximum compatibility
    muted_fg = 8 if curses.COLORS >= 16 else curses.COLOR_BLACK
    curses.init_pair(1, curses.COLOR_GREEN,  -1)   # green
    curses.init_pair(2, curses.COLOR_CYAN,   -1)   # cyan
    curses.init_pair(3, curses.COLOR_YELLOW, -1)   # yellow
    curses.init_pair(4, curses.COLOR_RED,    -1)   # red
    curses.init_pair(5, curses.COLOR_BLUE,   -1)   # blue
    curses.init_pair(6, muted_fg,            -1)   # muted (dark gray or black)
    curses.init_pair(7, curses.COLOR_WHITE,  -1)   # white
    curses.init_pair(8, curses.COLOR_BLACK,  curses.COLOR_CYAN)   # selected
    curses.init_pair(9, curses.COLOR_CYAN,   -1)   # header

COLOR = {
    'green':  lambda: curses.color_pair(1),
    'cyan':   lambda: curses.color_pair(2),
    'yellow': lambda: curses.color_pair(3),
    'red':    lambda: curses.color_pair(4),
    'blue':   lambda: curses.color_pair(5),
    'muted':  lambda: curses.color_pair(6),
    'white':  lambda: curses.color_pair(7),
    'sel':    lambda: curses.color_pair(8),
    'hdr':    lambda: curses.color_pair(9),
}
def c(name): return COLOR[name]()

def trunc(s: str, n: int) -> str:
    if len(s) > n: return s[:n-1] + '…'
    return s

def draw_box(win, y, x, h, w, title: str, active: bool):
    """Draw a box with title."""
    color = c('blue') | curses.A_BOLD if active else c('muted')
    win.erase()
    try:
        for row in range(1, h-1):
            win.addch(row, 0,   curses.ACS_VLINE, c('muted'))
            win.addch(row, w-1, curses.ACS_VLINE, c('muted'))
        win.hline(0,   1, curses.ACS_HLINE, w-2)
        win.hline(h-1, 1, curses.ACS_HLINE, w-2)
        win.addch(0,     0,   curses.ACS_ULCORNER, c('muted'))
        win.addch(0,     w-1, curses.ACS_URCORNER, c('muted'))
        win.addch(h-1,   0,   curses.ACS_LLCORNER, c('muted'))
    except:
        pass
    try:
        win.addch(h-1, w-1, curses.ACS_LRCORNER, c('muted'))
    except:
        pass
    label = f" {title} "
    try:
        win.addstr(0, 2, label, color)
    except:
        pass


def draw_panel_installed(win, state: AppState, active: bool):
    h, w = win.getmaxyx()
    draw_box(win, 0, 0, h, w, "Installed", active)

    inner_h = h - 2
    lst = state.inst_list
    total = len(lst)

    if total == 0:
        try: win.addstr(2, 2, "No packages found", c('yellow'))
        except: pass
        win.noutrefresh()
        return

    for i in range(inner_h):
        idx = state.inst_scr + i
        if idx >= total: break
        row = i + 1
        pkg = lst[idx]
        is_sel = (idx == state.inst_sel and active)
        name = trunc(pkg.name, 22)
        ver  = trunc(pkg.version or pkg.source, 14)
        try:
            if is_sel:
                win.addstr(row, 1, f" ▶ {name:<22} {ver:<14}", c('sel') | curses.A_BOLD)
            else:
                win.addstr(row, 1, " ✓ ", c('green'))
                win.addstr(row, 4, f"{name:<22}", c('white'))
                win.addstr(row, 27, f"{ver:<14}", c('muted'))
        except:
            pass

    # counter
    counter = f" {state.inst_sel+1}/{total} "
    try: win.addstr(h-1, w-len(counter)-1, counter, c('muted'))
    except: pass

    win.noutrefresh()


def draw_panel_search(win, state: AppState, active: bool):
    h, w = win.getmaxyx()
    draw_box(win, 0, 0, h, w, "Search nixpkgs", active)

    # Query line - always visible
    if state.typing:
        q_display = f"/ {state.query}_"
        try: win.addstr(1, 2, trunc(q_display, w-4), c('yellow') | curses.A_BOLD)
        except: pass
    elif state.query:
        q_display = f"/ {state.query}  (Enter=search)"
        try: win.addstr(1, 2, trunc(q_display, w-4), c('cyan'))
        except: pass
    else:
        hint = "/ type query, Enter to search"
        try: win.addstr(1, 2, trunc(hint, w-4), c('muted'))
        except: pass

    inner_h = h - 4
    lst = state.srch_list
    total = len(lst)
    for i in range(inner_h):
        idx = state.srch_scr + i
        if idx >= total: break
        row = i + 2
        pkg = lst[idx]
        is_sel = (idx == state.srch_sel and active)
        name = trunc(pkg.name, 22)
        ver  = trunc(pkg.version, 10)
        try:
            if is_sel:
                win.addstr(row, 1, f" ▶ {name:<22} {ver:<10}", c('sel') | curses.A_BOLD)
            else:
                win.addstr(row, 1, f"   {name:<22}", c('white'))
                win.addstr(row, 26, f"{ver:<10}", c('muted'))
        except:
            pass

    if total > 0:
        counter = f" {state.srch_sel+1}/{total} "
        try: win.addstr(h-1, w-len(counter)-1, counter, c('muted'))
        except: pass

    win.noutrefresh()


def draw_panel_log(win, state: AppState, active: bool):
    h, w = win.getmaxyx()
    draw_box(win, 0, 0, h, w, "Info / Log", active)

    iw = w - 4
    log_start = 1

    # Show selected package detail at top
    pkg = None
    if state.focus == 0 and state.inst_list:
        pkg = state.inst_list[state.inst_sel]
    elif state.focus == 1 and state.srch_list:
        pkg = state.srch_list[state.srch_sel]

    if pkg:
        try:
            win.addstr(1, 2, trunc(pkg.name, 24), c('green') | curses.A_BOLD)
            ver_str = pkg.version or pkg.source
            win.addstr(1, 28, trunc(ver_str, iw-28), c('cyan'))
            desc = pkg.description or "(no description)"
            win.addstr(2, 2, trunc(desc, iw), c('muted'))
            win.hline(3, 1, curses.ACS_HLINE, w-2)
        except:
            pass
        log_start = 4

    # Log lines
    log_h = h - 1 - log_start
    total = len(state.log_lines)
    for i in range(log_h):
        idx = state.log_scr + i
        if idx >= total: break
        txt, col = state.log_lines[idx]
        try:
            win.addstr(log_start + i, 2, trunc(txt, iw), c(col))
        except:
            pass

    win.noutrefresh()


def draw_topbar(win, state: AppState):
    h, w = win.getmaxyx()
    win.erase()
    try: win.addstr(0, 0, ' ' * (w-1), c('muted'))
    except: pass
    label = f" * nixpkg  {mode_label(state)} "
    try:
        win.addstr(0, 0, trunc(label, w-1), c('cyan') | curses.A_BOLD)
    except:
        pass
    win.noutrefresh()


def draw_bottombar(win, state: AppState):
    h, w = win.getmaxyx()
    win.erase()
    # Fill entire line with background
    try: win.addstr(0, 0, ' ' * (w-1), c('muted'))
    except: pass

    if state.loading:
        sp = SPINNER[state.spinner_i % len(SPINNER)]
        msg = f" {sp} {state.loading_msg} "
        try: win.addstr(0, 0, trunc(msg, w//2), c('yellow') | curses.A_BOLD)
        except: pass
    else:
        msg = f" {state.status} "
        col = c(state.status_color) | curses.A_BOLD
        try: win.addstr(0, 0, trunc(msg, w//2), col)
        except: pass

    hint = " [/]search [i]install [d]remove [r]reload [u]upd.index [tab]panel [j/k]nav [q]quit"
    hint_x = w // 2
    try: win.addstr(0, hint_x, trunc(hint, w - hint_x - 1), c('muted'))
    except: pass
    win.noutrefresh()


# ─────────────────────────────────────────────────────────────
# Navigation
# ─────────────────────────────────────────────────────────────
def nav_up(state: AppState, panel_h: int):
    if state.focus == 0 and state.inst_sel > 0:
        state.inst_sel -= 1
        if state.inst_sel < state.inst_scr:
            state.inst_scr = state.inst_sel
    elif state.focus == 1 and state.srch_sel > 0:
        state.srch_sel -= 1
        if state.srch_sel < state.srch_scr:
            state.srch_scr = state.srch_sel
    elif state.focus == 2 and state.log_scr > 0:
        state.log_scr -= 1

def nav_down(state: AppState, panel_h: int):
    if state.focus == 0 and state.inst_list:
        mx = len(state.inst_list) - 1
        if state.inst_sel < mx:
            state.inst_sel += 1
            vis = panel_h - 2
            if state.inst_sel >= state.inst_scr + vis:
                state.inst_scr = state.inst_sel - vis + 1
    elif state.focus == 1 and state.srch_list:
        mx = len(state.srch_list) - 1
        if state.srch_sel < mx:
            state.srch_sel += 1
            vis = panel_h - 4
            if state.srch_sel >= state.srch_scr + vis:
                state.srch_scr = state.srch_sel - vis + 1
    elif state.focus == 2:
        mx = len(state.log_lines) - 1
        if state.log_scr < mx:
            state.log_scr += 1

# ─────────────────────────────────────────────────────────────
# Log helper
# ─────────────────────────────────────────────────────────────
def add_log(state: AppState, text: str, color: str = 'muted'):
    state.log_lines.append((text, color))
    state.log_scr = max(0, len(state.log_lines) - 1)

# ─────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────
def main(stdscr):
    curses.cbreak()
    curses.noecho()
    stdscr.keypad(True)
    stdscr.timeout(50)   # 50ms tick for spinner
    curses.curs_set(0)
    init_colors()

    state = AppState()
    detect_mode(state)
    add_log(state, f"nixpkg started", 'green')
    add_log(state, f"Mode: {mode_label(state)}", 'muted')
    state.status = "Loading…"
    state.status_color = 'yellow'

    # Layout windows — created based on terminal size
    def make_windows(sh, sw):
        lw = sw * 2 // 5
        rw = sw - lw
        ih = (sh - 2) // 2
        srch_h = sh - 2 - ih
        rh = sh - 2

        top = curses.newwin(1,  sw, 0, 0)
        bot = curses.newwin(1,  sw, sh-1, 0)
        inst = curses.newwin(ih, lw, 1, 0)
        srch = curses.newwin(srch_h, lw, 1+ih, 0)
        log  = curses.newwin(rh, rw, 1, lw)
        return top, bot, inst, srch, log, ih, srch_h

    sh, sw = stdscr.getmaxyx()
    top, bot, inst_win, srch_win, log_win, ih, srch_h = make_windows(sh, sw)

    def redraw():
        nonlocal sh, sw, top, bot, inst_win, srch_win, log_win, ih, srch_h
        new_sh, new_sw = stdscr.getmaxyx()
        if (new_sh, new_sw) != (sh, sw):
            sh, sw = new_sh, new_sw
            stdscr.clear()
            top, bot, inst_win, srch_win, log_win, ih, srch_h = make_windows(sh, sw)

        draw_topbar(top, state)
        draw_panel_installed(inst_win, state, state.focus == 0)
        draw_panel_search(srch_win, state, state.focus == 1)
        draw_panel_log(log_win, state, state.focus == 2)
        draw_bottombar(bot, state)
        curses.doupdate()

    # Start loading installed packages
    op_load_installed(state)

    tick = 0
    while True:
        # Check background thread result
        with state.bg_lock:
            result = state.bg_result
            if result is not None:
                state.bg_result = None

        if result is not None:
            op = result.get('op', '')
            state.loading = False

            if op == 'load':
                state.inst_list = result.get('packages', [])
                state.inst_sel = 0; state.inst_scr = 0
                n = len(state.inst_list)
                if n == 0:
                    add_log(state, "⚠ No packages found", 'yellow')
                    state.status = "No packages found"
                    state.status_color = 'yellow'
                else:
                    add_log(state, f"✓ Loaded {n} packages", 'green')
                    state.status = f"{mode_label(state)}  ·  {n} packages"
                    state.status_color = 'green'

            elif op == 'search':
                state.srch_list = result.get('packages', [])
                state.srch_sel = 0; state.srch_scr = 0
                for txt, col in result.get('logs', []):
                    add_log(state, txt, col)
                if state.srch_list:
                    state.status = f"{len(state.srch_list)} results"
                    state.status_color = 'blue'
                else:
                    state.status = f"No results for '{state.query}'"
                    state.status_color = 'yellow'

            elif op in ('install', 'remove'):
                for txt, col in result.get('logs', []):
                    add_log(state, txt, col)
                ok = result.get('ok', False)
                if ok:
                    state.status = f"{'Install' if op=='install' else 'Remove'} OK"
                    state.status_color = 'green'
                    op_load_installed(state)
                    state.loading = True
                    state.loading_msg = "Reloading…"
                else:
                    state.status = f"{'Install' if op=='install' else 'Remove'} FAILED — see log"
                    state.status_color = 'red'

            redraw()

        # Handle input
        try:
            key = stdscr.getch()
        except:
            key = -1

        if key == -1:
            tick += 1
            if state.loading and tick % 4 == 0:
                state.spinner_i = (state.spinner_i + 1) % len(SPINNER)
                draw_bottombar(bot, state)
                curses.doupdate()
            continue

        # Typing mode (search input)
        if state.typing:
            if key in (ord('\n'), ord('\r'), 10, 13):
                state.typing = False
                if state.query:
                    state.srch_list = []
                    op_search(state, state.query)
            elif key == 27:   # ESC
                state.typing = False
            elif key == 9:    # Tab
                state.typing = False
                state.focus = (state.focus + 1) % 3
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                state.query = state.query[:-1]
            elif 32 <= key <= 126:
                state.query += chr(key)
            redraw()
            continue

        # Normal mode
        if key == ord('q') or key == ord('Q'):
            break
        elif key == 9:   # Tab
            state.focus = (state.focus + 1) % 3
        elif key in (curses.KEY_UP, ord('k')):
            nav_up(state, ih if state.focus == 0 else srch_h)
        elif key in (curses.KEY_DOWN, ord('j')):
            nav_down(state, ih if state.focus == 0 else srch_h)
        elif key == ord('g'):
            state.inst_sel = 0; state.inst_scr = 0
            state.srch_sel = 0; state.srch_scr = 0
        elif key == ord('G'):
            if state.inst_list: state.inst_sel = len(state.inst_list) - 1
            if state.srch_list: state.srch_sel = len(state.srch_list) - 1
        elif key == ord('/'):
            state.focus = 1; state.typing = True; state.query = ""
        elif key in (ord('\n'), ord('\r'), 10, 13):
            if state.focus == 1 and state.query and not state.loading:
                state.srch_list = []
                op_search(state, state.query)
        elif key == ord('i') or key == ord('I'):
            if not state.loading:
                op_install(state)
        elif key == ord('d') or key == ord('D'):
            if not state.loading:
                op_remove(state)
        elif key == ord('r') or key == ord('R'):
            add_log(state, "… reloading…", 'yellow')
            op_load_installed(state)
        elif key == ord('u') or key == ord('U'):
            if INDEX_FILE.exists():
                INDEX_FILE.unlink()
            add_log(state, "Index cleared — will rebuild on next search", 'yellow')
            state.status = "Index cleared — press / to search"
            state.status_color = 'yellow'
        elif key == curses.KEY_PPAGE:
            for _ in range(5): nav_up(state, ih)
        elif key == curses.KEY_NPAGE:
            for _ in range(5): nav_down(state, ih)
        elif key == curses.KEY_RESIZE:
            pass  # handled in redraw()

        redraw()


# ─────────────────────────────────────────────────────────────
# Preflight check
# ─────────────────────────────────────────────────────────────
def preflight():
    """Check for nix experimental features needed for some operations."""
    has = False
    try:
        r = subprocess.run(['nix','show-config'], capture_output=True, text=True, timeout=5)
        if 'nix-command' in r.stdout: has = True
    except: pass
    if not has:
        try:
            for f in ['/etc/nix/nix.conf', str(Path.home()/'.config/nix/nix.conf')]:
                if Path(f).exists() and 'nix-command' in open(f).read():
                    has = True; break
        except: pass

    if not has:
        print("\n  nixpkg — note: nix experimental-features not detected")
        print("  (needed for 'nix search', but NOT required — nixpkg uses local index instead)")
        print("  Skipping setup. Starting nixpkg...")


if __name__ == '__main__':
    preflight()
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
