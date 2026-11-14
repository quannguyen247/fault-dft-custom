#!/bin/sh
# Install the complete Fault+ environment without building dependencies on the host.
set -eu
case "${1-}" in
    -h|--help) printf 'Usage: ./install.sh [--build]\n\nInstalls Fault+ in ~/.local/bin. --build uses the local source.\n'; exit 0;;
    ''|--build) ;;
    *) echo 'Usage: ./install.sh [--build]' >&2; exit 2;;
esac
[ "$(uname -s)" = Linux ] || { echo 'This installer requires Linux.' >&2; exit 1; }
case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;;
    *) echo 'Prebuilt environments support Linux x86_64 and arm64.' >&2; exit 1;; esac
repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
revision=$(git -C "$repo" rev-parse HEAD 2>/dev/null || printf local)
image="localhost/faultplus:$revision"
engine=${FAULTPLUS_ENGINE-}
if [ -n "$engine" ]; then
    engine=$(command -v "$engine")
    "$engine" info >/dev/null 2>&1 || { echo 'The selected container engine is unavailable.' >&2; exit 1; }
else
    available=
    for candidate in podman docker; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" info >/dev/null 2>&1; then
            candidate=$(command -v "$candidate")
            if [ -z "$available" ]; then available=$candidate; fi
            if "$candidate" image inspect "$image" >/dev/null 2>&1; then engine=$candidate; break; fi
        fi
    done
    if [ -z "$engine" ]; then engine=$available; fi
fi
if [ -z "$engine" ]; then
    echo 'Installing Podman (the package manager may request your password).'
    if [ "$(id -u)" = 0 ]; then elevate=; elif command -v sudo >/dev/null 2>&1; then elevate=sudo;
    else echo 'Install Docker or Podman, then rerun ./install.sh.' >&2; exit 1; fi
    if command -v apt-get >/dev/null 2>&1; then
        $elevate apt-get update
        $elevate apt-get install -y podman curl
    elif command -v dnf >/dev/null 2>&1; then $elevate dnf install -y podman curl
    elif command -v yum >/dev/null 2>&1; then $elevate yum install -y podman curl
    elif command -v zypper >/dev/null 2>&1; then $elevate zypper --non-interactive install podman curl
    elif command -v pacman >/dev/null 2>&1; then $elevate pacman -S --needed --noconfirm podman curl
    elif command -v apk >/dev/null 2>&1; then $elevate apk add podman curl
    else echo 'Install Docker or Podman, then rerun ./install.sh.' >&2; exit 1; fi
    engine=$(command -v podman)
    "$engine" info >/dev/null 2>&1 || { echo 'Podman needs host setup; run podman info for the error.' >&2; exit 1; }
fi
engine_mode=docker
case "$("$engine" --version 2>/dev/null)" in *podman*) engine_mode=podman;; esac
if [ "$engine_mode" = docker ]; then
    case "$("$engine" info --format '{{json .SecurityOptions}}' 2>/dev/null)" in
        *rootless*) engine_mode=docker-rootless;;
    esac
fi
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT HUP INT TERM
build=no
if [ "${1-}" = --build ] || ! git -C "$repo" diff --quiet HEAD --; then build=yes; fi
if ! "$engine" image inspect "$image" >/dev/null 2>&1 || [ "$build" = yes ]; then
    downloaded=no
    if [ "$build" = no ] && command -v curl >/dev/null 2>&1; then
        asset="faultplus-linux-$arch.tar.gz"
        url="https://github.com/quannguyen247/fault-plus/releases/download/linux-$revision"
        echo 'Downloading the prebuilt Fault+ environment...'
        if curl -fsSL --retry 2 "$url/$asset.sha256" -o "$temp/$asset.sha256" \
            && curl -fSL --retry 2 "$url/$asset" -o "$temp/$asset"; then
            (cd "$temp" && sha256sum -c "$asset.sha256")
            gzip -dc "$temp/$asset" | "$engine" load
            downloaded=yes
        fi
    fi
    if [ "$downloaded" = no ]; then
        echo 'Building Fault+ from this checkout. The first build takes several minutes.'
        "$engine" build --build-arg "REVISION=$revision" -f "$repo/Containerfile" -t "$image" "$repo"
    fi
fi
"$engine" run --rm --entrypoint fault "$image" --version
"$engine" run --rm "$image" --version
prefix=${FAULTPLUS_PREFIX:-"$HOME/.local/bin"}
mkdir -p "$prefix"
# Quote generated shell assignments so spaces and apostrophes remain literal.
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
{
    printf '#!/bin/sh\nengine='; shell_quote "$engine"
    printf '\nimage='; shell_quote "$image"
    printf '\nengine_mode='; shell_quote "$engine_mode"
    printf '\n'
    cat "$repo/faultplus/container-run.sh"
} > "$temp/faultplus"
chmod +x "$temp/faultplus"
if [ -e "$prefix/faultplus" ] || [ -L "$prefix/faultplus" ]; then
    cp -Pp "$prefix/faultplus" "$temp/faultplus.previous"
    mv -fT "$temp/faultplus.previous" "$prefix/faultplus.previous"
fi
mv -fT "$temp/faultplus" "$prefix/faultplus"
printf '\nInstalled: %s/faultplus\n' "$prefix"
case ":$PATH:" in *":$prefix:"*) echo 'Run: faultplus';;
    *) printf 'Run: %s/faultplus\nAdd this directory to PATH: %s\n' "$prefix" "$prefix";; esac
