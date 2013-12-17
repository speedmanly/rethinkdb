#!/usr/bin/env bash

# A simple package manager for RethinkDB dependencies 
#
# Each package is a shell script that defines:
#
#  pkg_install: Build and install the package into $install_dir
#               If a build step is necessary, first copy the source from $src_dir into $install_dir/build
#
#  pkg_fetch: Fetch the package source into $src_dir
#             The fetch function must fetch the source into a temporary directory
#             And then move that temporary directory to $src_dir
#
#  pkg_install-include: Copy the include files to $install_dir/include
#
#  $version: The version of the package
#
# This pkg.sh script is called by ./configure and support/build.mk
# The first argument is the function that should be called
# The second argument is usually the package to load
# This script first defines utility functions used by the packages
# Then it loads the given package
# Then it calls the given command

set -eu

# Configure some default paths
pkg_dir=$(dirname $0)
conf_dir=$pkg_dir/../config

# These variables should be passed to this script from support/build.mk
WGET=${WGET:-}
CURL=${CURL:-}
OS=${OS:-}
COMPILER=${COMPILER:-}
CXX=${CXX:-}

# Print the version number of the package
pkg_version () {
    echo $version
}

pkg_environment () {
    test -d "$install_dir/include" && echo "export CXXFLAGS=\"\${LDFLAGS:-} -isystem $(niceabspath "$install_dir/include")\"" || :
    test -d "$install_dir/lib" && echo "export LDFLAGS=\"\${LDFLAGS:-} -L$(niceabspath "$install_dir/lib")\"" || :
    test -d "$install_dir/bin" && echo "export PATH=\"$(niceabspath "$install_dir/bin"):\$PATH\"" || :
}

pkg_make_tmp_fetch_dir () {
    tmp_dir=$(mktemp -d "$src_dir.fetch-XXXXXXXX")
}

pkg_remove_tmp_fetch_dir () {
    rm -rf "$tmp_dir"
}

pkg_fetch_archive () {
    pkg_make_tmp_fetch_dir

    local archive="${src_url##*/}"
    geturl "$src_url" > "$tmp_dir/$archive"

    local ext
    case "$archive" in
        *.tgz)     ext=tgz;     in_dir "$tmp_dir" tar -xzf "$archive" ;;
        *.tar.gz)  ext=tar.gz;  in_dir "$tmp_dir" tar -xzf "$archive" ;;
        *.tar.bz2) ext=tar.bz2; in_dir "$tmp_dir" tar -xjf "$archive" ;;
        *) error "don't know how to extract $archive"
    esac

    set -- "$tmp_dir"/*/

    if [[ "$#" != 1 ]]; then
        error "invalid archive contents: $archive"
    fi

    test -e "$src_dir" && rm -rf "$src_dir"

    mv "$1" "$src_dir"

    pkg_remove_tmp_fetch_dir
}

pkg_fetch_git () {
    pkg_make_tmp_fetch_dir

    git_clone_tag "$src_git_repo" "${src_git_ref:-$version}" "$tmp_dir"

    pkg_move_tmp_to_src
}

pkg_fetch () {
    if test -n "${src_url}"; then
        pkg_fetch_archive
    else
        error "fetch command for $pkg is broken. \$src_url should be defined"
    fi
}

pkg_move_tmp_to_src () {
    test -e "$src_dir" && rm -rf "$src_dir"
    mv "$tmp_dir" "$src_dir"
}

pkg_copy_src_to_build () {
    mkdir -p "$build_dir"
    cp -a "$src_dir/." "$build_dir"
}

pkg_install-include () {
    test -e "$install_dir/include" && rm -rf "$install_dir/include"
    mkdir -p "$install_dir/include"
    if [[ -e "$src_dir/include" ]]; then
        cp -a "$src_dir/include/." "$install_dir/include"
    fi
}

pkg_configure () {
    in_dir "$build_dir" ./configure --prefix="$(niceabspath "$install_dir")" "$@"
}

pkg_make () {
    in_dir "$install_dir/build" make "$@"
}


pkg_install () {
    pkg_copy_src_to_build
    pkg_configure
    pkg_make install
}

error () {
    echo "$*" >&2
    exit 1
}

# Include a file local to $pkg_dir
include () {
    local inc="$1"
    shift
    . "$pkg_dir/$inc" "$@"
}

# Utility function copied from the configure script
niceabspath () {
    if [[ -d "$1" ]]; then
        (cd "$1" && pwd) && return
    fi
    local dir=$(dirname "$1")
    if [[ -d "$dir" ]] && dir=$(cd "$dir" && pwd); then
        echo "$dir/$(basename "$1")" | sed 's|^//|/|'
        return
    fi
    if [[ "${1:0:1}" = / ]]; then
        echo "$1"
    else
        echo "$(pwd)/$1"
    fi
}

# in_dir <dir> <cmd> <args...>
# Run the command in dir
in_dir () {
    local dir="$1"
    shift
    ( cd "$dir" && "$@" )
}

# Load a package and set related variables
load_pkg () {
    pkg=$1
    include "$pkg.sh"

    src_dir=$pkg_dir/../src/$pkg\_$version
    install_dir=$pkg_dir/../../build/support/$pkg\_$version
    build_dir=$install_dir/build
}

# Test if the package has already been fetched
fetched () {
    test -e "$src_dir"
}

# Make a shallow clone of a specific git tag
git_clone_tag () {
    local remote tag repo
    remote=$1
    tag=$2
    repo=$3
    ( cd "$repo"
      git init
      git remote add origin "$remote"
      git fetch --depth 1 origin "$tag"
      git checkout FETCH_HEAD
      rm -rf .git
    )
}

# Download a file to stdout
geturl () {
    if [[ -n "${WGET:-}" ]]; then
        $WGET --quiet --output-document=- "$@"
    else
        ${CURL:-curl} --silent "$@"
    fi
}

pkg_script=$(niceabspath "$0")

pkg () {
    $pkg_script "$@"
}

# Read the command
cmd=$1
shift

# Load the package
load_pkg "$1"
shift

# Run the command
pkg_"$cmd" "$@" || { echo $0: failed command: $cmd $pkg "$@" >&2 ; false ; }
