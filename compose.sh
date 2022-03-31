#!/bin/sh

# If editing from Windows. Choose LF as line-ending

# This script (re-)implements docker-compose build, supporting a large subset of
# its CLI experience, and environment variables.

# Stop on errors and unset vars. Sane defaults
set -eu

# Compute the root directory where the script is located
COMPOSE_ROOTDIR=${COMPOSE_ROOTDIR:-"$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}

# Look for $2 in colon separated path-like in $1
pathfind() {
  # shellcheck disable=SC3043
  local _paths _name || true

  _paths=$1; shift
  printf %s\\n "$_paths"|sed 's/:/\n/g'|grep -vE '^$'|while IFS= read -r dir; do
    for _name in "$@"; do
      if [ -d "$dir" ]; then
        find "$dir" -mindepth 1 -maxdepth 1 -name "$_name" 2>/dev/null
      fi
    done
  done | head -n 1
}

COMPOSE_PATH_SEPARATOR=${COMPOSE_PATH_SEPARATOR:-":"}
COMPOSE_FILE=${COMPOSE_FILE:-"$(pathfind "$(pwd)" docker-compose.yml docker-compose.yaml)"}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-""}

DOCKER_HOST=${DOCKER_HOST:-""}

COMPOSE_VERBOSE=${COMPOSE_VERBOSE:-"0"}
if stat -c %F "$0" | grep -qiF "link"; then
  COMPOSE_REALDIR=$(cd -P -- "$(dirname -- "$(command -v -- "$(readlink "$0")")")" && pwd -P )
  COMPOSE_SHIM=${COMPOSE_SHIM:-"$(pathfind "${COMPOSE_REALDIR}:${COMPOSE_ROOTDIR}" "build.sh")"}
else
  COMPOSE_SHIM=${COMPOSE_SHIM:-"$(pathfind "${COMPOSE_ROOTDIR}" "build.sh")"}
fi

__LOG() {
    printf '[%s] [%s] %s\n' "$(date +'%Y%m%d-%H%M%S')" "$(basename "$0")" "${1:-}" >&2
}

INFO() { [ "$COMPOSE_VERBOSE" -ge "1" ] && __LOG "$1"; }
DEBUG() { [ "$COMPOSE_VERBOSE" -ge "2" ] && __LOG "$1"; }
ERROR() { __LOG "$1"; }

# shellcheck disable=SC2120
align() {
  # shellcheck disable=SC3043
  local line || true

  while IFS= read -r line; do
    printf "%s%s %s\n" \
      "$(printf "%.${1:-20}s\n" "$(printf "%s\n" "$line"|cut -d "${2:-":"}" -f 1)$(head -c "${1:-20}" < /dev/zero | tr '\0' ' ')")" \
      "${2:-":"}" \
      "$(printf %s\\n "$line"|cut -d "${2:-":"}" -f 2-)"
  done
}

# shellcheck disable=SC2120
usage() {
  sed -E 's/^\s+/  /g' <<-EOF
    $(basename "$0") is a compose build shim. It behaves like docker-compose build,
    supports a large subset of its options, but reimplements them directly on top
    of the docker client. The client can be an alternative build client, such as
    nerdctl or img.

    Global options, appear before sub-commands:
EOF
  head -150 "$0"  |
    grep -E '\s+-[a-zA-Z-].*)\s+#' |
    sed -E \
        -e 's/^\s+/    /g' \
        -e 's/\)\s+#\s+/:/g' |
    align

  printf "\n  Implemented sub-commands (-h to get command specific help):\n"
  grep -E '^cmd_.*\(\)' "$0" |
    sed -E \
      -e 's/^cmd_/    /g' \
      -e 's/\(\)\s*\{.*//g'
  exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f | --file)    # Specify an alternate compose file (default: docker-compose.yml)
      COMPOSE_FILE=$2; shift 2;;
    --file=*)
      COMPOSE_FILE="${1#*=}"; shift 1;;

    -p | --project) # Specify an alternate project name (default: directory name)
      COMPOSE_PROJECT_NAME=$2; shift 2;;
    --project=*)
      COMPOSE_PROJECT_NAME="${1#*=}"; shift 1;;

    --profile | --tlscacert | --tlscert | --tlskey | --tlsverify | --skip-hostname-check | --project-directory)
      ERROR "$1 not implemented/relevant"; shift 2;;
    --profile=* | --tlscacert=* | --tlscert=* | --tlskey=* | --tlsverify=* | --skip-hostname-check=* | --project-directory=*)
      ERROR "${1%=*} not implemented/relevant"; shift 1;;

    --verbose)    # Show more output
      COMPOSE_VERBOSE=1; shift;;

    --log-level)
      ERROR "--log-level not implemented and deprecated"; shift 2;;
    --log-level=*)
      ERROR "--log-level not implemented and deprecated"; shift 1;;

    --no-ansi | --tls | --compatibility)
      ERROR "$1 not implemented/relevant"; shift 2;;

    -v | --version)  # Print version and exit
      exec "$0" version;;

    -H | --host)  # Daemon socket to connect to
      DOCKER_HOST=$2; shift 2;;
    --host=*)
      DOCKER_HOST="${1#*=}"; shift 1;;

    -h | --help)  # Print help and return
      usage ;;

    -*)
      ERROR "${1%=*} unknown option!" >&2; usage 1;;

    *)
      break
  esac
done

if [ "$#" = "0" ]; then
  usage
fi

if [ -z "$COMPOSE_SHIM" ]; then
  ERROR "Cannot find compose shim underlying implementation!"; exit 1
fi
if ! [ -x "$COMPOSE_SHIM" ]; then
  ERROR "Compose shim underlying implementation at $COMPOSE_SHIM cannot be executed!"; exit 1
fi

# shellcheck disable=SC2120
_cmd_usage() {
  sed -E 's/^\s+/  /g' <<-EOF
    ${2:-}

    Options:
EOF
  grep -E -A 70 -e "^${1}" "$0" |
    grep -E '\s+-[a-zA-Z-].*)\s+#' |
    sed -E \
        -e 's/^\s+/    /g' \
        -e 's/\)\s+#\s+/:/g' |
  align
  exit "${3:-0}"
}

cmd_help() {
  usage
}

cmd_version() {
  printf "compose-build-shim version %s\n" \
    "$(grep '^BUILD_VERSION=' "$COMPOSE_SHIM" | head -n 1 | sed 's/^BUILD_VERSION=//')"
}

cmd_build() {
  # shellcheck disable=SC3043
  local opt_pull opt_cache opt_memory opt_rm opt_progress opt_compress opt_force_rm opt_quiet line build_args || true

  # Defaults
  opt_pull=0
  opt_force_rm=0
  opt_cache=1
  opt_memory=
  opt_rm=1
  opt_progress=auto
  opt_compress=0
  opt_quiet=0
  build_args=$(mktemp)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --build-arg)
        printf %s\\n "$2" >> "$build_args"; shift 2;;
      --build-arg=*)
        printf %s\\n "${1#*=}" >> "$build_args"; shift 1;;

      --compress)    # Compress the build context using gzip.
        opt_compress=1; shift;;

      --force-rm)    # Always remove intermediate containers.
        opt_force_rm=1; shift;;

      -m | --memory) # Set memory limit for the build container.
        opt_memory=$2; shift 2;;
      --memory=*)
        opt_memory="${1#*=}"; shift 1;;

      --no-cache)    # Do not use cache when building the image.
        opt_cache=0; shift;;

      --no-rm)       # Do not remove intermediate containers after a successful build.
        opt_rm=0; shift;;

      --parallel)
        ERROR "$1 not implemented"; shift;;

      --progress)    # Set type of progress output (`auto`, `plain`, `tty`).
        opt_progress=$2; shift 2;;
      --progress=*)
        opt_progress="${1#*=}"; shift 1;;

      --pull)        # Always attempt to pull a newer version of the image.
        opt_pull=1; shift;;

      -q | --quiet)  # Don't print anything to `STDOUT`.
        opt_quiet=1; shift;;

      -h | --help)   # Print help and return
        rm -f "$build_args"
        _cmd_usage "cmd_build" "build command will build or rebuild services from compose file" ;;

      *)
        rm -f "$build_args"
        ERROR "${1%=*} unknown option!" >&2; _cmd_usage "cmd_build" "build command will build or rebuild services from compose file";;
    esac
  done

  # Convert docker-compose CLI-compatible options to docker build compatible
  # options
  [ "$opt_pull" = "1" ] && set -- "$@" --pull
  [ "$opt_force_rm" = "1" ] && set -- "$@" --force-rm
  [ "$opt_cache" = "0" ] && set -- "$@" --no-cache
  [ -n "$opt_memory" ] && set -- "$@" --memory="$opt_memory"
  if [ "$opt_rm" = "0" ]; then
    set -- "$@" --rm=false
  else
    set -- "$@" --rm=true
  fi
  set -- "$@" --progress="$opt_progress"
  [ "$opt_compress" = "1" ] && set -- "$@" --compress
  [ "$opt_quiet" = "1" ] && set -- "$@" --quiet

  # Add the build arguments that were collected in the temporary file
  while IFS= read -r line || [ -n "$line" ]; do
    set -- "$@" --build-arg "$line"
  done < "$build_args"
  rm -f "$build_args"

  # Now set/export relevant variables and pass further everything to the underlying
  # implementation.
  BUILD_COMPOSE_BIN=
  export DOCKER_HOST BUILD_COMPOSE_BIN
  if [ "$COMPOSE_VERBOSE" -gt 0 ]; then
    exec "$COMPOSE_SHIM" \
      -f "$COMPOSE_FILE" \
      -b "auto" \
      -i "" \
      -c "" \
      -a -1 \
      -v \
      -- "$@"
  else
    exec "$COMPOSE_SHIM" \
      -f "$COMPOSE_FILE" \
      -b "auto" \
      -i "" \
      -c "" \
      -a -1 \
      -- "$@"
  fi
}

cmd__build() {
  if [ "$COMPOSE_VERBOSE" -gt 0 ]; then
    exec "$COMPOSE_SHIM" \
      -f "$COMPOSE_FILE" \
      -v \
      "$@"
  else
    exec "$COMPOSE_SHIM" \
      -f "$COMPOSE_FILE" \
      "$@"
  fi
}

is_function() {
  type "$1" | sed "s/$1//" | grep -qwi function
}

if is_function "cmd_$1"; then
  _cmd=cmd_$1
  shift
  "$_cmd" "$@"
else
  ERROR "$1 is an unimplemented command!"
  usage 1
fi
