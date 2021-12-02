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
  printf %s\\n "$1"|sed 's/:/\n/g'|grep -vE '^$'|while IFS= read -r dir; do
    find "$dir" -mindepth 1 -maxdepth 1 -name "$2" 2>/dev/null
  done | head -n 1
}

# Version of script, this should be increased for each new release of the script
BUILD_VERSION=1.4.0

# The location of the compose file. This file contains information about the
# images to generate.
BUILD_COMPOSE=${BUILD_COMPOSE:-$(pathfind "$(pwd):${BUILD_ROOTDIR%/}" docker-compose.yml)}

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

# Command to use to download stuff. This command should take an additional
# argument, the URL to download and dump the content of the URL to the stdout.
# When empty, the default, one of curl or wget, if present, will be used.
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
while getopts "a:b:c:f:i:r:s:t:hnpv?-" opt; do
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

# Poor man's logging
_message() { printf '[%s] [%s] [%s] %s\n' "$(basename -- "$0")" "${1:-DBG}" "$(date +'%Y%m%d-%H%M%S')" "$2" >&2; }
verbose() {
  if [ "$BUILD_VERBOSE" = "1" ]; then
    _message "NFO" "$1"
  fi
}
warn() { _message "WRN" "$1"; }


# Without a 2nd argument, this function will return the entire definition of the
# service which name is passed as a first argument. When a 2nd argument is
# given, it should be an integer and only the lines at this exact identation
# level passed will be returned
service() {
  # shellcheck disable=SC3043
  local svc_line end_line lvl || true

  if [ -z "${2:-}" ]; then
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
          tail +"$svc_line"
    else
      # There was an end_line, decrement by 1 and print out this sub-section
      # only.
      end_line=$(( end_line - 1))
      tail +"$svc_section" "$BUILD_COMPOSE" |
          tail +"$svc_line" |
          head -"$end_line"
    fi
  else
    # When an identation level is specified, do as if none was specify to get
    # the entire service definition, then isolate the keys. Arrange to have the
    # dash in the grep, in case an array is at this identation level.
    lvl=$(printf "%${2}s" "" | sed "s/ /${indent}/g"); # repeats indent $2 times
    service "$1" | grep -E "^${lvl}[a-z-]"
  fi
}


# Provided identation and the service section have been properly detected in the
# compose file, this function will look for the value of the keyword $3, in the
# service description of $1. The keyword should be at indentation level $2.
valueof() {
  service "$1" "$2" |
    grep "$3" |
    head -n 1 |
    sed -E "s/^[[:space:]]+${3}:(.*)/\\1/" |
    sed -E -e 's/^[[:space:]]+//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}


# Return the list of services
services() {
  tail +"$svc_section" "$BUILD_COMPOSE" |
    grep -E "^${indent}[a-zA-Z0-9].*:" |
    sed -E -e 's/^\s+//g' -e 's/:$//g'
}


# Change registry of the image passed as $1
reroot() {
  # shellcheck disable=SC3043
  local img ctag imgname || true

  # Extract the fully-qualified name of the image out of the first argument.
  img=$(printf %s\\n "$1"|grep -Eo '[a-zA-Z0-9.]+(:[0-9]+)?(/[a-zA-Z0-9_.-]+){1,3}')
  # Extract the tag. The regular expression works by refusing the : or the / in
  # the tag, the / is to handle the case where the registry is a DNS together
  # with a port (led by a colon, but there will be a slash after that colon).
  # Note that the tag WILL include the leading colon sign; this is on purpose.
  # The entire extraction goes through || true, because some images have no tag.
  ctag=$(printf %s\\n "$1"|grep -Eo ':[^:^/]+$' || true)
  # Extract the name of the image, i.e. everything after the LAST slash.
  imgname=$(printf %s\\n "$img" | awk -F / '{print $NF}')
  # Reroot under the registry passed as a second argument (or the default one
  # from BUILD_REGISTRY), keeping the same tag.
  printf %s/%s%s\\n "${2:-${BUILD_REGISTRY%/}}" "$imgname" "$ctag"
}


# Return the image to build/push for the service passed as first argument. When
# a second argument is specified, it is the tag to give to the image. When a
# different registry has been specified globally, the current registry of the
# image will be replace by the global registry.
image() {
  # shellcheck disable=SC3043
  local image || true

  image=$(valueof "$1" 2 "image")

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
  local image context dockerfile buildercmd || true

  # Pick image name to build, at proper tag
  if [ -z "${2:-}" ]; then
    verbose "Building image from service $1"
    image=$(image "$1")
  else
    verbose "Building image from service $1 (tag: $2)"
    image=$(image "$1" "${2}")
  fi

  context=$(valueof "$1" 2 "build")
  if [ -z "$context" ]; then
    # Pick context and Dockerfile location from the service description, default
    # to the same as docker-compose defaults.
    context=$(valueof "$1" 3 "context")
    if [ -z "$context" ]; then
      context=.
    fi
    dockerfile=$(valueof "$1" 3 "dockerfile")
    if [ -z "$dockerfile" ]; then
      dockerfile=$( find "$(dirname "$BUILD_COMPOSE")/${context}" \
                      -mindepth 1 -maxdepth 1 -iname Dockerfile |
                    head -n 1)
      if [ -n "$dockerfile" ]; then dockerfile=$(basename -- "$dockerfile"); fi
    fi
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
    buildercmd="${BUILD_DOCKER_BIN} build"
  else
    buildercmd="${BUILD_DOCKER_BIN} buildx build --load"
  fi

  # Perform build command, we do this in a sub-shell to be able to temporarily
  # change directory.
  if [ "$BUILD_DRYRUN" = "1" ]; then
    warn "Would run following in $context subdir: $buildercmd -t \"$image\" -f \"$dockerfile\" $*"
  else
    ( cd "$(dirname "$BUILD_COMPOSE")" \
      cd "${context}" \
      && $buildercmd -t "$image" -f "$dockerfile" "$@" . ) 1>&2

    # When we won't have to push, the list of images printed on the stdout is the
    # list of built images. So print the name of the image out.
    if [ "$BUILD_PUSH" = "0" ]; then
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

  if service "$1" 2 | grep -q build; then
    if [ "$BUILD_DRYRUN" = "1" ]; then
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
      if [ "$age" -lt "$BUILD_AGE" ] || [ "$BUILD_AGE" -le "0" ]; then
        verbose "Pushing $image to Docker registry"
        ${BUILD_DOCKER_BIN} push "$image" 1>&2
        # When we have to push, the list of images printed on the stdout is the
        # list of pushed images. So print the name of the image out.
        if [ "$BUILD_PUSH" = "1" ]; then
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
          if [ "$BUILD_DRYRUN" = "1" ]; then
            warn "Would load $2 file at $initfile"
          else
            warn "Loading $2 file at $initfile"
            "$initfile"
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
      if [ "$BUILD_DRYRUN" = "1" ]; then
        warn "Would run: ${BUILD_COMPOSE_BIN} -f \"$BUILD_COMPOSE\" build $*"
      else
        image=$(  ${BUILD_COMPOSE_BIN} -f "$BUILD_COMPOSE" build "$@" |
                  tee -a "$fifo" |
                  grep "Successfully tagged" |
                  sed -E 's/^Successfully tagged\s+(.*)/\1/')
        if [ "$BUILD_PUSH" = "0" ]; then
          BUILD_IMAGES="$BUILD_IMAGES $image"
          printf %s\\n "$image"
        fi
      fi
    else
      for svc in $BUILD_SERVICES; do
        if [ "$BUILD_DRYRUN" = "1" ]; then
          warn "Would run: ${BUILD_COMPOSE_BIN} -f \"$BUILD_COMPOSE\" build $* -- \"$svc\""
        else
          image=$(  ${BUILD_COMPOSE_BIN} -f "$BUILD_COMPOSE" build "$@" -- "$svc" |
                    tee -a "$fifo" |
                    grep "Successfully tagged" |
                    sed -E 's/^Successfully tagged\s+(.*)/\1/')
          if [ "$BUILD_PUSH" = "0" ]; then
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
      if service "$svc" 2 | grep -q build; then
        if [ -z "$BUILD_TAGS" ]; then
          docker_build "$svc" "" "$@"
        else
          main=
          for tag in $BUILD_TAGS; do
            if [ -z "$main" ]; then
              docker_build "$svc" "$tag" "$@"
              main=$tag
            else
              if [ "$BUILD_DRYRUN" = "1" ]; then
                warn "Would re-tag $(image "$svc" "$main") to $(image "$svc" "$tag")"
              else
                verbose "Re-tagging image from service $svc, tag: $tag"
                $BUILD_DOCKER_BIN image tag \
                  "$(image "$svc" "$main")" \
                  "$(image "$svc" "$tag")" 1>&2

                if [ "$BUILD_PUSH" = "0" ]; then
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
if [ "$BUILD_PUSH" = "1" ]; then
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
if [ -n "$BUILD_DOWNLOADER" ]; then
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
