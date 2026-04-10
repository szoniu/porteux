#!/usr/bin/env bash
# mirrors.sh — PorteuX download mirrors
# PorteuX is distributed via SourceForge and GitHub releases

# Primary download sources
readonly -a PORTEUX_MIRRORS=(
    "https://sourceforge.net/projects/porteux/files"
    "https://github.com/porteux/porteux/releases"
)

# get_mirror_list_for_dialog — Format mirror list for dialog menu
get_mirror_list_for_dialog() {
    local -a items=()
    items+=("sourceforge" "SourceForge (primary)" "on")
    items+=("github"      "GitHub Releases"       "off")
    echo "${items[@]}"
}
