#!/usr/bin/env bash

set -e

# ---------------- dependencies ----------------

if ! command -v fzf >/dev/null || ! command -v jq >/dev/null; then
    echo "Installing runtime dependencies..."
    exec nix shell nixpkgs#fzf nixpkgs#jq nixpkgs#bat nixpkgs#ripgrep -c "$0"
fi

# ---------------- config ----------------

CONFIG="/etc/nixos/configuration.nix"
CACHE_DIR="$HOME/.cache/nixui"
PKG_CACHE="$CACHE_DIR/packages"

mkdir -p "$CACHE_DIR"

# ---------------- colors ----------------

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
CYAN=$(tput setaf 6)
RESET=$(tput sgr0)

# ---------------- logging ----------------

log() {
    echo "${CYAN}[nixui]${RESET} $1"
}

error() {
    echo "${RED}[error]${RESET} $1"
}

# ---------------- cache builder ----------------

build_cache() {

    if [ -f "$PKG_CACHE" ]; then
        return
    fi

    log "Building nixpkgs cache (first run may take ~10-20s)"

    nix search nixpkgs . --json \
    | jq -r 'keys[]' > "$PKG_CACHE"

    log "Cache created"
}

# ---------------- installed packages ----------------

installed_packages() {

sed -n '/environment.systemPackages = with pkgs; \[/,/];/p' "$CONFIG" \
| sed '1d;$d' \
| sed 's/;//g' \
| sed 's/^ *//'
}

# ---------------- preview ----------------

preview_pkg() {

pkg="$1"

nix search nixpkgs "$pkg" 2>/dev/null | head -n 20
}

# ---------------- install ----------------

install_pkg() {

pkg="$1"

if grep -q " $pkg" "$CONFIG"; then
    log "$pkg already installed"
    return
fi

log "Installing $pkg"

sudo sed -i "/environment.systemPackages = with pkgs; \[/a\ \ \ \ $pkg" "$CONFIG"

sudo nixos-rebuild switch
}

# ---------------- remove ----------------

remove_pkg() {

pkg="$1"

log "Removing $pkg"

sudo sed -i "/ $pkg/d" "$CONFIG"

sudo nixos-rebuild switch
}

# ---------------- versions ----------------

show_versions() {

pkg="$1"

clear
echo "Versions for $pkg"
echo

nix search nixpkgs "$pkg"

echo
read -p "Press enter..."
}

# ---------------- rebuild ----------------

rebuild_system() {

log "Running nixos-rebuild"

sudo nixos-rebuild switch
}

# ---------------- help ----------------

help_screen() {

clear

cat <<EOF

nixui - NixOS TUI package manager

keys:

ENTER      install
CTRL-D     remove
CTRL-V     versions
CTRL-R     rebuild
CTRL-I     installed packages
ESC        quit

EOF

read -p "Press enter..."
}

# ---------------- installed viewer ----------------

show_installed() {

clear

echo "Installed packages:"
echo

installed_packages

echo
read -p "Press enter..."
}

# ---------------- main UI ----------------

main_ui() {

build_cache

while true
do

selection=$(cat "$PKG_CACHE" | fzf \
  --multi \
  --border \
  --layout=reverse \
  --prompt="nixui > " \
  --header="ENTER install | CTRL-D remove | CTRL-V versions | CTRL-R rebuild | CTRL-I installed | ESC quit" \
  --expect=enter,ctrl-d,ctrl-v,ctrl-r,ctrl-i \
  --preview 'nix search nixpkgs {} | head -n 20' \
  --preview-window right:60%)

key=$(head -n1 <<< "$selection")
pkg=$(tail -n +2 <<< "$selection")

[ -z "$pkg" ] && exit

case "$key" in

enter)

for p in $pkg
do
install_pkg "$p"
done

;;

ctrl-d)

for p in $pkg
do
remove_pkg "$p"
done

;;

ctrl-v)

show_versions "$pkg"

;;

ctrl-r)

rebuild_system

;;

ctrl-i)

show_installed

;;

*)

;;

esac

done
}

# ---------------- start ----------------

main_ui
