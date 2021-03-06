#!/bin/sh

# If editing from Windows. Choose LF as line-ending

# This script builds (and push) Docker images that have build information in a
# docker-compose file.

# Stop on errors and unset vars. Sane defaults
set -eu

# Compute the root directory where the script is located
BUILD_ROOTDIR=${BUILD_ROOTDIR:-"$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}

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

# Source the reg-tags implementation, this uses a search path in order to
# facilitate relocating (e.g. from Docker image).
# shellcheck disable=SC1090   # Dynamic search on purpose
. "$(pathfind "${BUILD_ROOTDIR%/}/lib/reg-tags:${BUILD_ROOTDIR%/}/../lib:${BUILD_ROOTDIR%/}/../share/docker-compose-build" image_api.sh)"

# Version of script, this should be increased for each new release of the script
BUILD_VERSION=1.7.4

# The location of the compose file. This file contains information about the
# images to generate.
BUILD_COMPOSE=${BUILD_COMPOSE:-$(pathfind "$(pwd):${BUILD_ROOTDIR%/}" compose.yaml compose.yml docker-compose.yaml docker-compose.yml)}

# The list of services to build/push for. When empty, this will be a good guess
# of all services (the guess is perfect when building with compose).
BUILD_SERVICES=${BUILD_SERVICES:-}

# What builder to use. This can be compose, docker, build, buildx or auto. build
# and docker are just aliases for the same. When running with compose, the
# script will run docker-compose build. In all other cases, the script will
# analyse the compose file to detect services, images, contexts and dockerfile
# and pass proper arguments to docker build (or buildx). auto will resolve to
# the best available of buildx or docker.
BUILD_BUILDER=${BUILD_BUILDER:-"compose"}

# Should we also push the generated images to the registry.
BUILD_PUSH=${BUILD_PUSH:-0}

# List of tags to give images (does not work with compose)
BUILD_TAGS=${BUILD_TAGS:-}

# Secondary Docker registry to build for and push to (does not work with
# compose)
BUILD_REGISTRY=${BUILD_REGISTRY:-}

# Age of the image for pushes to be allowed (this avoid pushing old images, just
# a failsafe measure)
BUILD_AGE=${BUILD_AGE:-1200}

# Print out more information on stderr
BUILD_VERBOSE=${BUILD_VERBOSE:-0}

# Perform a dry-run, i.e. don't build, don't push, but show what would be done.
BUILD_DRYRUN=${BUILD_DRYRUN:-0}

# How to run the docker and docker-compose clients
BUILD_DOCKER_BIN=${BUILD_DOCKER_BIN:-"docker"}
BUILD_COMPOSE_BIN=${BUILD_COMPOSE_BIN:-"docker-compose"}

# Directories to source any initialisation/cleanup scripts from. When -, the
# default, this will be the build-init.d (or build-cleanup.d) directories in the
# same directory than the compose file and the BUILD_ROOTDIR.
BUILD_INIT_DIR=${BUILD_INIT_DIR:-"-"}
BUILD_CLEANUP_DIR=${BUILD_CLEANUP_DIR:-"-"}

# Executable files matching this and found in the init and cleanup directories
# will be ignored (this is a wrong-but-usable fix against Windows mounting text
# files with the exec. flag by default). Test will be performed on the basename
# of the path.
BUILD_IGNORE=${BUILD_IGNORE:-'*.md'}

# Command to use to download stuff. This command should take an additional
# argument, the URL to download and dump the content of the URL to the stdout.
# When empty, the default, one of curl or wget, if present, will be used. When a
# dash, version check will be disabled.
BUILD_DOWNLOADER=${BUILD_DOWNLOADER:-}

# Name of the project at GitHub, there is is little point in changing this...
BUILD_GH_PROJECT=Mitigram/docker-compose-build

usage() {
  # This uses the comments behind the options to show the help. Not extremly
  # correct, but effective and simple.
  echo "$0 builds (and push) Docker images. Arguments passed to compose/build. Usage:" && \
    grep "[[:space:]].)\ #" "$0" |
    sed 's/#//' |
    sed -r 's/([a-z])\)/-\1/'
  exit "${1:-0}"
}

# Use standard getops. Options first, then flags, in alphabetical order
while getopts "a:b:c:g:f:i:r:s:t:hnpv?-" opt; do
  # The order of this case statement is used for printing out the usage
  # description. So, rather than having it in the same order as the getopts
  # string spec. above, the options and flags are arranged in order of priority:
  # from most important to less.
  case "$opt" in
    f) # Path to docker compose file to use. Defaults to docker-compose.yml in current directory or same directory as script.
      BUILD_COMPOSE=$OPTARG;;
    p) # Should the built images be pushed to the registry?
      BUILD_PUSH=1;;
    b) # Builder to use: compose, auto, docker or buildx
      BUILD_BUILDER=$OPTARG;;
    t) # Tag to give to images, forces use of auto for builder when specified.
      BUILD_TAGS=$OPTARG;;
    r) # Docker registry+leading path to push to, instead of the one from Docker compose file. Forces use of auto for builder when specified
      BUILD_REGISTRY=$OPTARG;;
    s) # List of (compose) services to build/push, defaults to all that have a build context
      BUILD_SERVICES=$OPTARG;;
    i) # Colon separated list of directories which content will be executed after init, before build
      BUILD_INIT_DIR=$OPTARG;;
    c) # Colon separated list of directories which content will be executed once all images built and pushed
      BUILD_CLEANUP_DIR=$OPTARG;;
    g) # Glob-pattern to ignore some files from the init and cleanup directories.
      BUILD_IGNORE=$OPTARG;;
    a) # Maximum age of the image when pushing, older will be discarded. Negative to turn off.
      BUILD_AGE=$OPTARG;;
    n) # Just show what would be done instead
      BUILD_DRYRUN=1;;
    v) # More verbosity on stderr
      BUILD_VERBOSE=1;;
    h | \?) # Print this help and exit
      usage;;
    -)
      break;;
    *)
      usage 1;;
  esac
done

# Shift forward, everything remaining at the command line will be passed to
# docker-compose build or docker build (depending on the chosen builder).
shift $((OPTIND-1))

# Booleans
to_lower() { printf %s\\n "$1" | tr '[:upper:]' '[:lower:]'; }
is_true() {
    [ "$1" = "1" ] \
    || [ "$(to_lower "$1")" = "true" ] \
    || [ "$(to_lower "$1")" = "on" ] \
    || [ "$(to_lower "$1")" = "yes" ]; }
is_false() {
    [ "$1" = "0" ] \
    || [ "$(to_lower "$1")" = "false" ] \
    || [ "$(to_lower "$1")" = "off" ] \
    || [ "$(to_lower "$1")" = "no" ]; }
# Poor man's logging
_message() { printf '[%s] [%s] [%s] %s\n' "$(basename -- "$0")" "${1:-DBG}" "$(date +'%Y%m%d-%H%M%S')" "$2" >&2; }
verbose() {
  if is_true "$BUILD_VERBOSE"; then
    _message "NFO" "$1"
  fi
}
warn() { _message "WRN" "$1"; }


# Performs word splitting on "$2" (the separator)
split() {
  # shellcheck disable=SC3043
  local _oldstate || true

  [ -z "$2" ] && echo "$1" && return

  # Disable globbing. This ensures that the word-splitting is safe.
  _oldstate=$(set +o); set -f

  # Store the current value of 'IFS' so we can restore it later.
  old_ifs=$IFS

  # Change the field separator to what we're splitting on.
  IFS=$2

  # Create an argument list splitting at each occurance of '$2'.
  #
  # This is safe to disable as it just warns against word-splitting which is the
  # behavior we expect.
  # shellcheck disable=2086
  set -- $1

  # Print each list value on its own line.
  printf '%s\n' "$@"

  # Restore the value of 'IFS'.
  IFS=$old_ifs

  # Restore globbing state
  set +vx; eval "$_oldstate"
}


# Performs glob matching with explicit support for |, which otherwise is outside
# POSIX. See:
# https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_13
# $1 is the matching pattern
# $2 is the string to test against
glob() {
  # shellcheck disable=SC3043
  local _oldstate || true

  # Disable globbing. This ensures that the case is not globbed.
  _oldstate=$(set +o); set -f
  for ptn in $(split "$1" "|"); do
      # shellcheck disable=2254
      case "$2" in
          $ptn) set +vx; eval "$_oldstate"; return 0;;
      esac
  done
  set +vx; eval "$_oldstate"
  return 1
}


# returns the entire definition of the service which name is passed as a first
# argument.
service() {
  # shellcheck disable=SC3043
  local svc_line end_line || true

  # Find the line (within the services section) where the service definition
  # for $1 starts.
  svc_line=$( tail +"$svc_section" "$BUILD_COMPOSE" |
              grep -En "^${indent}${1}:" |
              cut -d: -f1 )
  # Find the end line, or rather the line at which the next service definition
  # starts. This might be empty, when the service is last in the file
  end_line=$( tail +"$svc_section" "$BUILD_COMPOSE" |
              tail +"$svc_line" |
              grep -En "^${indent}[a-zA-Z0-9].*:" |
              tail +2 |
              head -1 |
              cut -d: -f1 )
  if [ -z "$end_line" ]; then
    # No end_line, service was last, just tail
    tail +"$svc_section" "$BUILD_COMPOSE" |
        tail +"$svc_line" |
        grep -v '^[[:space:]]*#.*'
  else
    # There was an end_line, decrement by 1 and print out this sub-section
    # only.
    end_line=$(( end_line - 1))
    tail +"$svc_section" "$BUILD_COMPOSE" |
        tail +"$svc_line" |
        head -"$end_line" |
        grep -v '^[[:space:]]*#.*'
  fi
}


# Return the list of services
services() {
  tail +"$svc_section" "$BUILD_COMPOSE" |
    grep -E "^${indent}[a-zA-Z0-9].*:" |
    sed -E -e 's/^\s+//g' -e 's/:$//g'
}


# Return the number of spaces matching the indentation level passed as $1
indent() {
  printf "%${1}s" "" | sed "s/ /${indent}/g"; # repeats indent $1 times
}


# Provided identation and the service section have been properly detected in the
# compose file, this function will look for the tree under the keyword "$1" at
# indentation level "$2". The line containing the keywork "$1" itself is
# NOT returned as a part of the tree.
treeof() {
  # shellcheck disable=SC3043
  local lvl || true

  lvl=$(indent "$2")
  sed -nE "/^${lvl}${1}/,/^${lvl}[a-zA-Z0-9.-_]/p" | grep -E "^${lvl}${indent}"
}


unquote() {
  sed -E \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e 's/^"//' \
    -e 's/"$//' \
    -e "s/^'//" \
    -e "s/'$//"
}


# Given a YAML snippet, look for the value of the first occurence of "$1". When
# "$2" is not empty, it should be an indentation level and "$1" is forced to be
# at that level.
valueof() {
  # shellcheck disable=SC3043
  local lvl || true

  lvl='[[:space:]]+'
  if [ -n "${2:-}" ]; then
    lvl=$(indent "$2")
  fi

  grep -E "^[[:space:]]+${1}" |
    head -n 1 |
    sed -E "s/^${lvl}${1}:(.*)/\\1/" |
    unquote
}


# Given a YAML snippet, check if it has a key "$1". When "$2" is not empty, it
# should be an indentation level and "$1" is forced to be at that level.
haskey() {
  # shellcheck disable=SC3043
  local lvl || true

  lvl='[[:space:]]+'
  if [ -n "${2:-}" ]; then
    lvl=$(indent "$2")
  fi

  grep -Eq "^${lvl}${1}"
}


# Given a service $1, with a tree starting at "$2" under the build spec,
# construct as many CLI setting commands as there are values under $2. Each CLI
# setting command will be prefixed with --$3. This is used to transform the
# values under args or labels into CLI options and values that will be then
# passed to docker build.
unwind() {
  # The while-loop narrows down to the proper tree, and remove all leading
  # spaces to ease parsing below.
  while IFS= read -r line; do
    if printf %s\\n "$line" | grep -q '^-'; then
      # This is in array-style, pick up the = setting string from the compose
      # file and pass as is after unquoting (we will always force quotes).
      printf '%s "%s" ' "--$3" "$(printf %s\\n "$line" | sed -E 's/^-[[:space:]]+//' | unquote)"
    else
      # Otherwise, this is a "key: val"-style. Extract the key and the value and
      # format a proper CLI option out of them.

      # shellcheck disable=SC3043
      local key val || true

      # Extract key and val, based on the occurence of the first ":" sign
      key=$(printf %s\\n "$line" | sed -E 's/^([^:]+):.*/\1/')
      val=$(printf %s\\n "$line" | sed -E "s/^[^:]+:(.*)/\\1/" | unquote)
      # Create CLI setting option, forcing quotes around
      printf '%s "%s=%s" ' "--$3" "$key" "$val"
    fi
  done <<EOF
$(service "$1" | treeof "build" 2| treeof "$2" 3 | sed -E 's/^[[:space:]]+//g')
EOF
  printf \\n
}

# Extract tag of an image, defaulting to the one passed as a second parameter
# when specified and no tag present in image
imgtag() {
  # shellcheck disable=SC3043
  local ctag || true

  # Extract the tag. The regular expression works by refusing the : or the / in
  # the tag, the / is to handle the case where the registry is a DNS together
  # with a port (led by a colon, but there will be a slash after that colon).
  # Note that the tag WILL include the leading colon sign; this is on purpose.
  # The entire extraction goes through || true, because some images have no tag.
  ctag=$(printf %s\\n "$1"|grep -Eo ':[^:^/]+$' || true)
  if [ -z "$ctag" ] && [ -n "${2:-}" ]; then
    ctag=$2
  fi
  printf %s\\n "${ctag#:}"
}

# Extract name of image, i.e. everything except the tag
imgname() {
  printf %s\\n "$1"|grep -Eo '[a-zA-Z0-9.]+(:[0-9]+)?(/[a-zA-Z0-9_.-]+){1,3}'
}

# Change registry of the image passed as $1
reroot() {
  # shellcheck disable=SC3043
  local img ctag imgname || true

  # Extract the fully-qualified name and tag of the image out of the first
  # argument.
  img=$(imgname "$1")
  ctag=$(imgtag "$1")
  # Extract the name of the image, i.e. everything after the LAST slash.
  imgname=$(printf %s\\n "$img" | awk -F / '{print $NF}')
  # Reroot under the registry passed as a second argument (or the default one
  # from BUILD_REGISTRY), keeping the same tag (or no tag if none was specified
  # from the start).
  if [ -z "$ctag" ]; then
    printf %s/%s\\n "${2:-${BUILD_REGISTRY%/}}" "$imgname"
  else
    printf %s/%s:%s\\n "${2:-${BUILD_REGISTRY%/}}" "$imgname" "$ctag"
  fi
}


# Return the image to build/push for the service passed as first argument. When
# a second argument is specified, it is the tag to give to the image. When a
# different registry has been specified globally, the current registry of the
# image will be replace by the global registry.
image() {
  # shellcheck disable=SC3043
  local image || true

  image=$(service "$1" | valueof "image" 2)

  # Does the image contain a reference to a shell variable of some sort?
  # shellcheck disable=SC2016 # We **want** to detect the $ sign!!
  if printf %s\\n "$image" | grep -qE '\${?[A-Z_]+'; then
    # When it does, we resolve the value of the variable through evaluation
    # an output of the image content. This is ugly...
    image=$(eval echo "$image")
  fi

  # If a specific build tag is specified, either we replace the existing tag
  # of the image, or we just add it to the image name.
  if [ -n "${2:-}" ]; then
    if printf %s\\n "$image" | grep -qE ':[^:^/]+$'; then
      image=$(printf %s\\n "$image" | sed -E 's|:[^:^/]+$|:'"${2#:}"'|')
    else
      image="${image}:${2#:}"
    fi
  fi

  if [ -z "$BUILD_REGISTRY" ]; then
    printf %s\\n "$image"
  else
    printf %s\\n "$(reroot "$image" "$BUILD_REGISTRY")"
  fi
}


# Build the image for the service passed as a first parameter, forcing its tag
# to be the value of the second parameter.  When the second argument is empty,
# the original tag from the image will be kept. All other arguments will be
# blindly passed to the docker build command.
docker_build() {
  # shellcheck disable=SC3043
  local image context dockerfile buildercmd buildArgs labels cli || true

  # Pick image name to build, at proper tag
  if [ -z "${2:-}" ]; then
    verbose "Building image from service $1"
    image=$(image "$1")
  else
    verbose "Building image from service $1 (tag: $2)"
    image=$(image "$1" "${2}")
  fi

  context=$(service "$1" | valueof "build")
  buildArgs=
  labels=
  cli=
  if [ -z "$context" ]; then
    # Pick context and Dockerfile location from the service description, default
    # to the same as docker-compose defaults.
    context=$(service "$1" | treeof "build" 2 | valueof "context" 3)
    if [ -z "$context" ]; then
      context=.
    fi
    dockerfile=$(service "$1" | treeof "build" 2| valueof "dockerfile" 3)
    if [ -z "$dockerfile" ]; then
      dockerfile=$( find "$(dirname "$BUILD_COMPOSE")/${context}" \
                      -mindepth 1 -maxdepth 1 -iname Dockerfile |
                    head -n 1)
      if [ -n "$dockerfile" ]; then dockerfile=$(basename -- "$dockerfile"); fi
    fi

    # Add build arguments and labels from file
    if service "$1" | treeof "build" 2 | haskey "args" 3; then
      buildArgs=$(unwind "$1" "args" "build-arg")
    fi
    if service "$1" | treeof "build" 2 | haskey "labels" 3; then
      labels=$(unwind "$1" "labels" "label")
    fi

    # Carry further other command-line arguments.
    for key in target network shm_size; do
      if service "$1" | treeof "build" 2 | haskey "$key" 3; then
        cli="$cli --$(printf %s\\n "${key}"|tr '_' '-') \"$(service "$1" | treeof "build" 2 | valueof "$key" 3)\""
      fi
    done
  else
    dockerfile=$( find "$(dirname "$BUILD_COMPOSE")/${context}" \
                    -mindepth 1 -maxdepth 1 -iname Dockerfile |
                  head -n 1)
    if [ -n "$dockerfile" ]; then dockerfile=$(basename -- "$dockerfile"); fi
  fi

  # Give up building if we don't have a Dockerfile set
  if [ -z "$dockerfile" ]; then
    warn "Cannot find default Dockerfile in $(dirname "$BUILD_COMPOSE")/${context}!"
    return 0
  fi

  # Done with the two first arguments, everything else will be passed further to
  # docker build.
  shift 2

  # Decide upon command to use for building, e.g. old-style docker build or
  # new buildx with BuildKit.
  if [ "$BUILD_BUILDER" = "docker" ]; then
    buildercmd="${BUILD_DOCKER_BIN} build $buildArgs $labels $cli"
  else
    buildercmd="${BUILD_DOCKER_BIN} buildx build --load $buildArgs $labels $cli"
  fi

  # Perform build command, we do this in a sub-shell to be able to temporarily
  # change directory. This uses eval to properly carry on quoting from the $cli,
  # $buildArgs and $labels variables (via the $dockercmd variable).
  if is_true "$BUILD_DRYRUN"; then
    warn "Would run following in $context subdir: $buildercmd -t \"$image\" -f \"$dockerfile\" $* ."
  else
    verbose "Running in $context subdir: $buildercmd -t \"$image\" -f \"$dockerfile\" $* ."
    ( cd "$(dirname "$BUILD_COMPOSE")" \
      && cd "${context}" \
      && eval "$buildercmd" -t "$image" -f "$dockerfile" "$*" . ) 1>&2

    # When we won't have to push, the list of images printed on the stdout is the
    # list of built images. So print the name of the image out.
    if is_false "$BUILD_PUSH"; then
      BUILD_IMAGES="$BUILD_IMAGES $image"
      printf %s\\n "$image"
    fi
  fi
}


# Push the image for the service passed as a first parameter, forcing its tag
# to be the value of the second parameter.  When the second argument is empty,
# the original tag from the image will be kept.
image_push() {
  # shellcheck disable=SC3043
  local image isodate tstamp now age || true

  # Pick image name to push, at proper tag
  if [ -z "${2:-}" ]; then
    verbose "Conditionally pushing image from service $1"
    image=$(image "$1")
  else
    verbose "Conditionally pushing image from service $1 (tag: $2)"
    image=$(image "$1" "${2}")
  fi

  if service "$1" | haskey "build" 2; then
    if is_true "$BUILD_DRYRUN"; then
      if [ "$BUILD_AGE" -le "0" ]; then
        warn "Would push $image if it existed"
      else
        warn "Would push $image if it had been created within $BUILD_AGE seconds"
      fi
    elif ${BUILD_DOCKER_BIN} image inspect "$image" >/dev/null 2>&1; then
      # Extract the ISO8601 when the image was last created
      isodate=$(  ${BUILD_DOCKER_BIN} image inspect "$image" |
                  grep Created |
                  sed -E 's/\s+"Created"\s*:\s*"([^"]+)".*/\1/' )
      # Convert the ISO8601 date to the number of seconds since the epoch. This
      # removes the T and remove the milli/microseconds from the date string to
      # arrange for date -d to be able to parse. Note: On busybox, this will
      # loose seconds, but this isn't a big deal for us.
      tstamp=$(date -d "$(printf %s\\n "$isodate"  | sed -E -e 's/([0-9])T([0-9])/\1 \2/' -e 's/\.[0-9]+/ /')" +%s)
      # Compute how old the image is and push only if it is young, i.e. we've
      # just built it.
      now=$(date +%s)
      age=$(( now - tstamp ))
      if ! img_tags "$(imgname "$image")" | grep -qF "$(imgtag "$image" latest)" \
          || [ "$age" -lt "$BUILD_AGE" ] \
          || [ "$BUILD_AGE" -le "0" ]; then
        verbose "Pushing $image to Docker registry"
        ${BUILD_DOCKER_BIN} push "$image" 1>&2
        # When we have to push, the list of images printed on the stdout is the
        # list of pushed images. So print the name of the image out.
        if is_true "$BUILD_PUSH"; then
          BUILD_IMAGES="$BUILD_IMAGES $image"
          printf %s\\n "$image"
        fi
      else
        warn "$image is too old, last created: $isodate"
      fi
    fi
  fi
}


# Execute all init/cleanup programs present in the colon separated list of
# directories passed as $1. The second argument is used to log what type of
# files this is (initialisation, cleanup).
execute() {
  printf %s\\n "$1" |
    sed 's/:/\n/g' |
    grep -vE '^$' |
    while IFS= read -r dir
  do
    if [ -d "$dir" ]; then
      verbose "Executing all executable files directly under '$dir', in alphabetical order"
      find -L "$dir" -maxdepth 1 -mindepth 1 -name '*' -type f -executable |
        sort | while IFS= read -r initfile; do
          if glob "$BUILD_IGNORE" "$(basename "$initfile")"; then
            warn "Ignoring file $initfile, matches '$BUILD_IGNORE'"
          else
            if is_true "$BUILD_DRYRUN"; then
              warn "Would load $2 file at $initfile"
            else
              warn "Loading $2 file at $initfile"
              "$initfile"
            fi
          fi
        done
    fi
  done
}


#########
# STEP 1: Initialisation and Run-Time Checks
#########

# Cannot continue without a docker-compose file
if [ -z "$BUILD_COMPOSE" ] || ! [ -f "$BUILD_COMPOSE" ]; then
  warn "Cannot find compose file at ${BUILD_COMPOSE}!"
  exit 1
fi

# Change builder when a tag or registry are specified, or when docker-compose
# isn't installed at all.
if [ "$BUILD_BUILDER" = "compose" ]; then
  if ! command -v "${BUILD_COMPOSE_BIN}" >/dev/null 2>&1; then
    warn "Using auto builder instead, ${BUILD_COMPOSE_BIN} not installed or accessible from PATH"
    BUILD_BUILDER="auto"
  fi
  if [ -n "$BUILD_TAGS" ]; then
    warn "Using auto builder instead, as a different tag is specified"
    BUILD_BUILDER="auto"
  fi
  if [ -n "$BUILD_REGISTRY" ]; then
    warn "Using auto builder instead, as a different registry is specified"
    BUILD_BUILDER="auto"
  fi
fi

# Test value of builder, and presence of docker CLI
case "$BUILD_BUILDER" in
  compose ) ;;
  auto | docker | build* )
    if ! command -v "${BUILD_DOCKER_BIN}" >/dev/null 2>&1; then
      warn "${BUILD_DOCKER_BIN} not installed or accessible from PATH"
      exit 1
    fi
    ;;
  "" )
    verbose "Empty builder, no build will be performed"
    ;;
  * )
    warn "$BUILD_BUILDER is not a known builder type!"
    exit 1
    ;;
esac

# Resolve auto to the best available of docker buildx or old-style docker.
if [ "$BUILD_BUILDER" = "auto" ]; then
  if ${BUILD_DOCKER_BIN} buildx >/dev/null 2>&1; then
    verbose "Using buildx for building image(s)"
    BUILD_BUILDER=buildx
  else
    verbose "Using old-style docker build"
    BUILD_BUILDER=docker
  fi
fi

# Guess the characters used for indentation in the compose file and where the
# services section starts in the file.
indent=$(grep -E '^\s+' "$BUILD_COMPOSE" |head -n 1|sed -E 's/^(\s+).*/\1/')
svc_section=$(grep -En '^services' "$BUILD_COMPOSE"|cut -d: -f1)

# Guess command to execute for Web downloads.
if [ -z "${BUILD_DOWNLOADER:-}" ]; then
  if command -v "curl" >/dev/null 2>&1; then
    BUILD_DOWNLOADER="curl -sSL"
  elif command -v "wget" >/dev/null 2>&1; then
    BUILD_DOWNLOADER="wget -q -O -"
  else
    verbose "Could neither find curl, nor wget. Will not check for new versions"
  fi
fi

# Initialise init and cleanup directory paths, based on the location of the
# compose file, when these were the -
if [ "$BUILD_INIT_DIR" = "-" ]; then
  BUILD_INIT_DIR=$(dirname "$BUILD_COMPOSE")/build-init.d:${BUILD_ROOTDIR%/}/build-init.d
  verbose "Automatically set initialisation dir path to: $BUILD_INIT_DIR"
fi
if [ "$BUILD_CLEANUP_DIR" = "-" ]; then
  BUILD_CLEANUP_DIR=$(dirname "$BUILD_COMPOSE")/build-cleanup.d:${BUILD_ROOTDIR%/}/build-cleanup.d
  verbose "Automatically set cleanup dir path to: $BUILD_CLEANUP_DIR"
fi


#########
# STEP 2: Out-of-Script Initialisation via Directory Content
#########

# Exports all variables starting with BUILD_ so initialisation programs/scripts,
# if any can take decisions.
for v in $(set | grep -E '^BUILD_' | sed -E 's/^(BUILD_[A-Z_]+)=.*/\1/g'); do
  # shellcheck disable=SC2163
  export "$v"
done

# Arrange to execute all programs/scripts that are present in the colon
# separated list of directories passed as BUILD_INIT_DIR.
execute "$BUILD_INIT_DIR" "initialisation"

# Initialise set of built/pushed images
BUILD_IMAGES=


#########
# STEP 3: Build Images
#########

if [ -n "$BUILD_BUILDER" ]; then
  if [ -z "$BUILD_SERVICES" ]; then
    verbose "Will build all services out of $BUILD_COMPOSE"
  else
    verbose "Will build following services from $BUILD_COMPOSE: $BUILD_SERVICES"
  fi
fi

# Build image
case "$BUILD_BUILDER" in
  compose)
    # We will be running with compose, so we need to analyse its output in order
    # to be able to print out the name of the images that are created by the
    # build commands. For this to happen, while still catching errors, we'll
    # make a fifo that we will dump (to stderr) which capturing and analysing
    # the result of compose in real-time.
    fifo=$(mktemp -tu compose-XXXXX.log)
    mkfifo "$fifo"
    cat "$fifo" >&2 &
    # When running with compose, we can rely on compose to analyse the YAML
    # file. So we just run docker-compose build, for all or just the services
    # specified.
    if [ -z "$BUILD_SERVICES" ]; then
      if is_true "$BUILD_DRYRUN"; then
        warn "Would run: ${BUILD_COMPOSE_BIN} -f \"$BUILD_COMPOSE\" build $*"
      else
        image=$(  ${BUILD_COMPOSE_BIN} -f "$BUILD_COMPOSE" build "$@" |
                  tee -a "$fifo" |
                  grep "Successfully tagged" |
                  sed -E 's/^Successfully tagged\s+(.*)/\1/')
        if is_false "$BUILD_PUSH"; then
          BUILD_IMAGES="$BUILD_IMAGES $image"
          printf %s\\n "$image"
        fi
      fi
    else
      for svc in $BUILD_SERVICES; do
        if is_true "$BUILD_DRYRUN"; then
          warn "Would run: ${BUILD_COMPOSE_BIN} -f \"$BUILD_COMPOSE\" build $* -- \"$svc\""
        else
          image=$(  ${BUILD_COMPOSE_BIN} -f "$BUILD_COMPOSE" build "$@" -- "$svc" |
                    tee -a "$fifo" |
                    grep "Successfully tagged" |
                    sed -E 's/^Successfully tagged\s+(.*)/\1/')
          if is_false "$BUILD_PUSH"; then
            BUILD_IMAGES="$BUILD_IMAGES $image"
            printf %s\\n "$image"
          fi
        fi
      done
    fi
    rm -f "$fifo"
    ;;
  docker | build*)
    # Detect list of services to build
    if [ -z "$BUILD_SERVICES" ]; then
      BUILD_SERVICES=$(services)
    fi

    for svc in $BUILD_SERVICES; do
      if service "$svc" | haskey "build" 2; then
        if [ -z "$BUILD_TAGS" ]; then
          docker_build "$svc" "" "$@"
        else
          main=
          for tag in $BUILD_TAGS; do
            if [ -z "$main" ]; then
              docker_build "$svc" "$tag" "$@"
              main=$tag
            else
              if is_true "$BUILD_DRYRUN"; then
                warn "Would re-tag $(image "$svc" "$main") to $(image "$svc" "$tag")"
              else
                verbose "Re-tagging image from service $svc, tag: $tag"
                $BUILD_DOCKER_BIN image tag \
                  "$(image "$svc" "$main")" \
                  "$(image "$svc" "$tag")" 1>&2

                if is_false "$BUILD_PUSH"; then
                  BUILD_IMAGES="$BUILD_IMAGES $(image "$svc" "$tag")"
                  printf %s\\n "$(image "$svc" "$tag")"
                fi
              fi
            fi
          done
        fi
      else
        verbose "Service $svc has no build information"
      fi
    done
    ;;
esac


#########
# STEP 4: Push Images
#########

# Push if requested
if is_true "$BUILD_PUSH"; then
  # Detect list of services to build
  if [ -z "$BUILD_SERVICES" ]; then
    BUILD_SERVICES=$(services)
  fi

  for svc in $BUILD_SERVICES; do
    if [ -z "$BUILD_TAGS" ]; then
      image_push "$svc"
    else
      for tag in $BUILD_TAGS; do
        image_push "$svc" "$tag"
      done
    fi
  done
fi


#########
# STEP 5: Out-of-Script Cleanup via Directory Content
#########

# Arrange for the list of images that were built or pushed (pushed images have
# precedence) to be given to the cleanup scripts.
BUILD_IMAGES=$(printf %s\\n "$BUILD_IMAGES" | sed -E 's/^ //')
export BUILD_IMAGES

# Arrange to execute all programs/scripts that are present in the colon
# separated list of directories passed as BUILD_CLEANUP_DIR.
execute "$BUILD_CLEANUP_DIR" "cleanup"


#########
# STEP 6: Check for New Versions
#########
if [ -n "$BUILD_DOWNLOADER" ] && [ "$BUILD_DOWNLOADER" != "-" ]; then
  verbose "Checking latest version of project $BUILD_GH_PROJECT at GitHub"
  # Pick the latest release out of the HTML for the releases description. This
  # avoids the GitHub API on purpose to avoid being rate-limited.
  release=$(  $BUILD_DOWNLOADER "https://github.com/${BUILD_GH_PROJECT}/releases" |
              grep -Eo "href=\"/${BUILD_GH_PROJECT}/releases/tag/v?[0-9]+(\\.[0-9]+){1,2}\"" |
              grep -v no-underline |
              sort -r |
              head -n 1 |
              cut -d '"' -f 2 |
              awk '{n=split($NF,a,"/");print a[n]}' |
              awk 'a !~ $0{print}; {a=$0}' |
              grep -Eo "[0-9]+(\\.[0-9]+){1,2}" )
  if [ "$release" != "$BUILD_VERSION" ]; then
    warn "v$release of this script is available, you are running v$BUILD_VERSION"
  fi
fi
