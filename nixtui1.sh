#!/usr/bin/env bash

# ---- auto dependencies ----

if ! command -v fzf >/dev/null || ! command -v jq >/dev/null; then
    echo "Installing runtime dependencies..."

    exec nix shell nixpkgs#fzf nixpkgs#jq nixpkgs#dialog -c "$0"
fi

CONFIG="/etc/nixos/configuration.nix"
CACHE="/tmp/nixui-packages"

build_cache() {

    if [ ! -f "$CACHE" ]; then
        echo "Building nixpkgs cache..."
        nix search nixpkgs . --json | jq -r 'keys[]' > "$CACHE"
    fi
}

installed_packages() {

    sed -n '/environment.systemPackages = with pkgs; \[/,/];/p' "$CONFIG" \
    | sed '1d;$d' \
    | sed 's/;//g'
}

pkg_info() {

    nix search nixpkgs "$1" | head -n 20
}

install_pkg() {

    pkg=$1

    if grep -q " $pkg" "$CONFIG"; then
        return
    fi

    sudo sed -i "/environment.systemPackages = with pkgs; \[/a\ \ \ \ $pkg" "$CONFIG"

    sudo nixos-rebuild switch
}

remove_pkg() {

    pkg=$1

    sudo sed -i "/ $pkg/d" "$CONFIG"

    sudo nixos-rebuild switch
}

main_ui() {

    build_cache

    while true
    do

        pkg=$(cat "$CACHE" | fzf \
            --multi \
            --border \
            --layout=reverse \
            --preview 'nix search nixpkgs {} | head -n 20' \
            --preview-window right:60% \
            --header "i install | d delete | r rebuild | q quit")

        [ -z "$pkg" ] && exit

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

            r)
                sudo nixos-rebuild switch
                ;;

            q)
                exit
                ;;

        esac

    done
}

main_ui
