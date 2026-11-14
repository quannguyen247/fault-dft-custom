# The installer writes the engine and image variables before this script.
set -eu
workdir=$(pwd -P)
case "$workdir" in *:*) echo 'Fault+: the working directory cannot contain a colon.' >&2; exit 2;; esac
run_user="$(id -u):$(id -g)"
if [ "$engine_mode" = docker-rootless ]; then run_user=0:0; fi
set -- run --rm -i --user "$run_user" \
    --security-opt label=disable --env "HOME=${HOME:-/tmp}" --env TMPDIR=/tmp --env FAULT_THREADS \
    --volume "$workdir:$workdir" --workdir "$workdir" "$image" "$@"
if [ -t 0 ] && [ -t 1 ]; then terminal=yes; else terminal=no; fi
# Preserve access to user libraries and scripts outside the current project.
if [ -n "${HOME-}" ] && [ -d "$HOME" ] && [ "$HOME" != "$workdir" ]; then
    shift
    set -- run --volume "$HOME:$HOME" "$@"
fi
# Podman keeps the caller's UID in a rootless user namespace.
if [ "$engine_mode" = podman ]; then
    shift
    set -- run --userns=keep-id "$@"
fi
if [ "$terminal" = yes ]; then
    shift
    set -- run -t "$@"
fi
exec "$engine" "$@"
