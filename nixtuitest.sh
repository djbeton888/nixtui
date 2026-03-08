#!/usr/bin/env bash

# ---------------- dependencies ----------------

if ! command -v fzf >/dev/null || ! command -v jq >/dev/null; then
    echo "Installing runtime dependencies..."
    exec nix shell nixpkgs#fzf nixpkgs#jq -c "$0"
fi

CONFIG="/etc/nixos/configuration.nix"
CACHE="$HOME/.cache/nixui"
PKG_CACHE="$CACHE/packages"

mkdir -p "$CACHE"

# ---------------- cache nixpkgs ----------------

build_cache() {

    if [ ! -f "$PKG_CACHE" ]; then
        echo "Building nixpkgs cache (first run may take ~10s)..."
        nix search nixpkgs . --json \
        | jq -r 'keys[]' > "$PKG_CACHE"
    fi
}

# ---------------- installed packages ----------------

installed() {

sed -n '/environment.systemPackages = with pkgs; \[/,/];/p' "$CONFIG" \
| sed '1d;$d' \
| sed 's/;//g'
}

# ---------------- package preview ----------------

preview() {

pkg="$1"

nix search nixpkgs "$pkg" 2>/dev/null | head -n 20
}

# ---------------- install ----------------

install_pkg() {

pkg="$1"

if grep -q " $pkg" "$CONFIG"; then
    return
fi

sudo sed -i "/environment.systemPackages = with pkgs; \[/a\ \ \ \ $pkg" "$CONFIG"

echo "Installing $pkg..."
sudo nixos-rebuild switch
}

# ---------------- remove ----------------

remove_pkg() {

pkg="$1"

sudo sed -i "/ $pkg/d" "$CONFIG"

echo "Removing $pkg..."
sudo nixos-rebuild switch
}

# ---------------- versions ----------------

versions() {

pkg="$1"

nix search nixpkgs "$pkg" | less
}

# ---------------- main ui ----------------

main() {

build_cache

while true
do

pkg=$(cat "$PKG_CACHE" | fzf \
--border \
--layout=reverse \
--multi \
--prompt="nixui > " \
--header="/ search | space select | i install | d delete | v versions | r rebuild | q quit" \
--preview 'nix search nixpkgs {} | head -n 20' \
--preview-window right:60%)

[ -z "$pkg" ] && exit

echo
echo "Selected:"
echo "$pkg"
echo

echo "[i] install  [d] delete  [v] versions  [r] rebuild  [q] quit"

read -rsn1 key

case "$key" in

i)
for p in $pkg
do
install_pkg "$p"
done
;;

d)
for p in $pkg
do
remove_pkg "$p"
done
;;

v)
versions "$pkg"
;;

r)
sudo nixos-rebuild switch
;;

q)
exit
;;

esac

done
}

main
