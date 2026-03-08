#!/usr/bin/env bash

set -e

# ---------- CONFIG DETECTION ----------

if [ -f /etc/nixos/flake.nix ]; then
    MODE="flake"
    CONFIG="/etc/nixos"
elif [ -f /etc/nixos/configuration.nix ]; then
    MODE="classic"
    CONFIG="/etc/nixos/configuration.nix"
else
    dialog --msgbox "NixOS config not found" 8 40
    exit 1
fi


# ---------- FUNCTIONS ----------

rebuild() {
    if [ "$MODE" = "flake" ]; then
        sudo nixos-rebuild switch --flake /etc/nixos
    else
        sudo nixos-rebuild switch
    fi
}

get_installed() {

    if [ "$MODE" = "classic" ]; then
        sed -n '/environment.systemPackages = with pkgs; \[/,/];/p' "$CONFIG" \
        | sed '1d;$d' \
        | sed 's/;//g'
    else
        grep -o 'pkgs\.[a-zA-Z0-9._-]*' -r /etc/nixos | cut -d. -f2
    fi
}


install_packages() {

    query=$(dialog --inputbox "Search packages" 8 40 3>&1 1>&2 2>&3)

    [ -z "$query" ] && return

    results=$(nix search nixpkgs "$query" 2>/dev/null \
        | grep '^*' \
        | awk '{print $2}' \
        | head -n 30)

    menu=()

    while read -r pkg; do
        [ -z "$pkg" ] && continue
        menu+=("$pkg" "" off)
    done <<< "$results"

    selections=$(dialog \
        --checklist "Select packages to install" \
        20 60 15 \
        "${menu[@]}" \
        3>&1 1>&2 2>&3)

    [ -z "$selections" ] && return

    for pkg in $selections; do
        pkg=$(echo $pkg | tr -d '"')

        if [ "$MODE" = "classic" ]; then
            sudo sed -i "/environment.systemPackages = with pkgs; \[/a\ \ \ \ $pkg" "$CONFIG"
        fi
    done

    rebuild
}


remove_package() {

    pkgs=$(get_installed)

    menu=()

    while read -r pkg; do
        [ -z "$pkg" ] && continue
        menu+=("$pkg" "")
    done <<< "$pkgs"

    pkg=$(dialog \
        --menu "Remove package" \
        20 60 15 \
        "${menu[@]}" \
        3>&1 1>&2 2>&3)

    [ -z "$pkg" ] && return

    sudo sed -i "/ $pkg/d" "$CONFIG"

    rebuild
}


show_installed() {

    pkgs=$(get_installed)

    dialog --title "Installed packages" \
        --msgbox "$pkgs" \
        20 60
}


package_info() {

    query=$(dialog --inputbox "Package name" 8 40 3>&1 1>&2 2>&3)

    [ -z "$query" ] && return

    info=$(nix search nixpkgs "$query" 2>/dev/null | head -n 20)

    dialog --title "Package info" \
        --msgbox "$info" \
        20 70
}


fast_search() {

    if ! command -v nix-locate >/dev/null; then
        dialog --msgbox "nix-index not installed" 8 40
        return
    fi

    query=$(dialog --inputbox "File search (nix-index)" 8 40 3>&1 1>&2 2>&3)

    results=$(nix-locate "$query" | head -n 20)

    dialog --title "Search results" \
        --msgbox "$results" \
        20 70
}


# ---------- MAIN MENU ----------

while true
do

choice=$(dialog \
--clear \
--title "NixOS TUI Manager" \
--menu "Select option" \
20 60 10 \
1 "Search & install packages" \
2 "Installed packages list" \
3 "Remove package" \
4 "Package description" \
5 "Fast search (nix-index)" \
6 "Rebuild system" \
7 "Exit" \
3>&1 1>&2 2>&3)

case $choice in

1) install_packages ;;
2) show_installed ;;
3) remove_package ;;
4) package_info ;;
5) fast_search ;;
6) rebuild ;;
7) clear; exit ;;

esac

done
