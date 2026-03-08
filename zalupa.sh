#!/usr/bin/env bash

set -e

# ---------- dependencies ----------

if ! command -v fzf >/dev/null || ! command -v jq >/dev/null; then
    echo "Installing runtime dependencies..."
    exec nix shell nixpkgs#fzf nixpkgs#jq -c "$0"
fi

CONFIG="/etc/nixos/configuration.nix"

CACHE="$HOME/.cache/nixui"
PKG_CACHE="$CACHE/packages"

mkdir -p "$CACHE"

# ---------- build package cache ----------

build_cache() {

if [ ! -f "$PKG_CACHE" ]; then

    echo "Building nix package index..."

    nix-env -qaP --description \
    | awk '{print $1}' \
    | sed 's/nixpkgs\.//' \
    > "$PKG_CACHE"

    echo "Index ready."

fi

}

# ---------- installed packages ----------

installed() {

sed -n '/environment.systemPackages = with pkgs; \[/,/];/p' "$CONFIG" \
| sed '1d;$d' \
| sed 's/;//g' \
| sed 's/^ *//'

}

# ---------- preview ----------

preview() {

pkg="$1"

nix search nixpkgs "$pkg" 2>/dev/null | head -n 20

}

# ---------- install ----------

install_pkg() {

pkg="$1"

if grep -q " $pkg" "$CONFIG"; then
    echo "$pkg already installed"
    sleep 1
    return
fi

sudo sed -i "/environment.systemPackages = with pkgs; \[/a\ \ \ \ $pkg" "$CONFIG"

echo "Installing $pkg..."

sudo nixos-rebuild switch

}

# ---------- remove ----------

remove_pkg() {

pkg="$1"

sudo sed -i "/ $pkg/d" "$CONFIG"

echo "Removing $pkg..."

sudo nixos-rebuild switch

}

# ---------- versions ----------

versions() {

pkg="$1"

clear

echo "Available versions:"
echo

nix search nixpkgs "$pkg"

echo
read -p "Press Enter..."

}

# ---------- rebuild ----------

rebuild() {

sudo nixos-rebuild switch

}

# ---------- installed list ----------

show_installed() {

clear

echo "Installed packages:"
echo

installed

echo
read -p "Press Enter..."

}

# ---------- main UI ----------

main() {

build_cache

while true
do

selection=$(cat "$PKG_CACHE" | fzf \
--multi \
--layout=reverse \
--border \
--prompt="nixui > " \
--header="ENTER install | CTRL-D remove | CTRL-V versions | CTRL-R rebuild | CTRL-I installed | ESC quit" \
--expect=enter,ctrl-d,ctrl-v,ctrl-r,ctrl-i \
--preview 'nix search nixpkgs {} | head -n 20' \
--preview-window right:60%)

key=$(head -n1 <<< "$selection")
pkg=$(tail -n +2 <<< "$selection")

[ -z "$pkg" ] && continue

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

versions "$pkg"

;;

ctrl-r)

rebuild

;;

ctrl-i)

show_installed

;;

esac

done

}

main
