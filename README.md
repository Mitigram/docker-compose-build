# docker-compose-build

Using `docker-compose` in dev, but a more complex orchestrator in production?
This [script](#command-line-and-environment-configuration) (and GitHub
[action](#github-action)) uses the (Docker) [compose] file to capture building
information for your images, but can help out when pushing to several registries
or tagging them with a release number (from a GitHub workflow?), for example.
The script supplements and/or replaces `docker(-)compose build` with direct
calls to `docker build` in order to:

+ [Push](#option--b-and-build_builder-variable) the resulting image(s) to their
  registries.
+ [Replace](#option--r-and-build_registry-variable) the registry settings from
  the compose file with another one, if necessary.
+ [Re-tag](#option--t-and-build_tags-variable), or add tags to the images that
  will be built and/or pushed.
+ Perform some (automated)
  [initialisation](#option--i-and-build_init_dir-variable) actions prior to
  building/pushing.
+ Perform some (automated) [cleanup](#option--c-and-build_cleanup_dir-variable)
  actions once all images have been built and/or pushed. This can be used to
  trigger actions at the orchestration layer, for example.

This script has sane defaults. If `docker-compose` is installed, its default
behaviour is to build all or some of the services that are pointed at by the
(Docker) [compose] file in the current directory. When operations such as
pushing, retagging or changing the destination registry are requested, the
script will actively read the content of the compose file and pick the
necessary information from there. At the time of writing, this will work best
when the `services` section is last in the file.

The result of this script is a list of the Docker images that were built (or
[pushed](#flag--p-and-build_push-variable), depending) on `stdout`, one per
line. This is to facilitate automation. All other output (logging, output of
`docker` or `docker-compose`, etc.) is redirected to `stderr`.

The project even implements a [replacement](#docker-compose-shim) for
`docker-compose` `build` (and `push`), with a similar UX at the CLI (i.e. same
set of options and flags).

To use this script in your projects, you can either make this project a
[submodule] or [subtree] of your main project. The script will print a warning
when a new version is available. This script itself makes [use] of a [reg-tags]
as a [subtree] to interact with remote Docker registries without downloading the
images.

  [compose]: https://compose-spec.io/
  [submodule]: https://git-scm.com/book/en/v2/Git-Tools-Submodules
  [subtree]: https://git-memo.readthedocs.io/en/latest/subtree.html
  [use]: ./lib/README.md
  [reg-tags]: https://github.com/efrecon/reg-tags

## Example

### Compose Example

The script is designed to work against compose files according to the following
[skeleton](./example/docker-compose.yml):

```yaml
version: "2.2"

services:
  myservice:
    build:
      context: .
      dockerfile: Dockerfile
    image: myregistry.mydomain.com/myimage
```

### Pure Relay

When `docker-compose` is installed, the following command would simply relay
calling the `build` sub-command of `docker-compose`. When `docker-compose` is
not installed (but `docker` is), the script will automatically switch to
building with the `docker` CLI client. As the default is to read information
from the `docker-compose.yml` file, the resulting image will be as if it had
been created by running `docker-compose build`.

```shell
./build.sh
```

### Building with Docker

When run with the following command, the script will build using the `docker`
CLI client. It will automatically pick `buildx` or old-style `build`, in that
order, and depending on your local installation. The behaviour is the same as
when running with `docker-compose`: only images that have a `build` context will
be built.

```shell
./build.sh -b auto
```

### Adding a Tag

When run with the following command, the script will automatically add the tag
`test` to the image that is being built. Adding a tag will automatically depart
from the default `docker-compose`-based build and use the installed `docker`
instead.

```shell
./build.sh -t test
```

## Command-Line and Environment Configuration

The script accepts a number of command-line options and flags. Its behaviour can
also be changed through a number of environment variables, all starting with the
`BUILD_` prefix. Command-line options and flags always have precedence over
variables. All further arguments to the script will be blindly passed to
`docker-compose` or `docker` when building. To ensure correctness, you can
separate the command-line options and flags, from the arguments using a
double-dash, i.e. `--`.

### Flag `-h`

Provide quick usage summary at the terminal and exit.

### Flag `-v` and `BUILD_VERBOSE` Variable

When the flag is given or the variable set to `1`, the script will describe the
various steps that it performs more verbosedly on the `stderr`.

### Flag `-n` and `BUILD_DRYRUN` Variable

When the flag is given or the variable set to `1`, the script will only describe
the various steps that it would perform on the `stderr`, but not actually do
anything. No image name will be printed out on the `stdout`, as no image was
built or pushed.

### Option `-f` and `BUILD_COMPOSE` Variable

Specifies the location of the compose file to use. The default is to look for
the following files, in that order, first in the current directory, then in the
same directory as the script is located at:

1. `compose.yaml`
2. `compose.yml`
3. `docker-compose.yaml`
4. `docker-compose.yml`

### Flag `-p` and `BUILD_PUSH` Variable

When the flag is given or the variable set to `1`, the images specified by the
compose file will also be pushed to their respective registries, once building
has finished. Your local `docker` client must have enough credentials to access
the remote registries. Old images will automatically be
[skipped](#option--a-and-build_age-variable).

### Option `-b` and `BUILD_BUILDER` Variable

Specifies the builder to use, can be one of:

+ `compose` (the default): will try hard to use compose, but will revert to the
  `auto` builder (see below) when `docker-compose` is not installed.
+ `auto`: will pick the best of the new `buildx` or old-style `docker build`,
  depending on which is available, and in that order, i.e. `buildx` preferred.
+ `buildx`: will use the new `buildx` for building. This requires the `buildx`
  Docker plugin to be available and properly installed.
+ `docker` or `build`: will use the old-style `docker build` command.
+ An empty string: will not build anything, only push in case
  [`-p`](#flag--p-and-build_push-variable) was specified. Out-of-script
  [initialisation](#option--i-and-build_init_dir-variable) will still happen.
  This facilitates running the script in two distinct phases, i.e. first build,
  then push, as in the following example:

```shell
./build.sh;          # Build, do not push
./build.sh -b "" -p; # Do not build, but push
```

### Option `-s` and `BUILD_SERVICES` Variable

Specifies the space separated list of services to build. These services need to
exist in the compose file. When empty, the default, the script will default to
building/pushing all the services specified in the compose file.

### Option `-t` and `BUILD_TAGS` Variable

Specifies the space separated list of tags to give to the images that will be
built/pushed. When building, the image with the first tag in the list will be
built, while images with the other tags will be tagged with the first image as
the source. The default is to not specified any tag, in which case the tag from
the compose file will be picked up and used, if any.

### Option `-r` and `BUILD_REGISTRY` Variable

Specifies an alternative registry to use instead of the one specified as part of
the compose file. When no registry is given, the default, the registry will be
the one from the compose file.

### Option `-a` and `BUILD_AGE` Variable

Specifies the maximum age of the image since creation to decide whether it
should be pushed or not. This is a safety measure to avoid pushing "junk" images
that would have been built at a prior run of the script, but without the
[`-p`](#flag--p-and-build_push-variable) flag. The default of `1200` seconds
should work in most cases, but any negative value will turn this check off,
meaning that all relevant images will be pushed, disregarding their age.

The implementation will **always** check if the destination image (and tag)
exists at the remote registry. When it does not, and disregarding the specified
age, the image will be pushed to ensure its existence.

### Option `-i` and `BUILD_INIT_DIR` Variable

Specifies a list of directory paths, separated by the colon `:` sign wherefrom
to find and execute initialisation actions. All exectuable (scripts or programs)
in these directories will automatically be executed once the script
initialisation has ended and before build and push operations are about to
start. Initialisation happens in the order of the directories in the path, and
in the alphabetical order of the executable files, within each directory. All
variables starting with `BUILD_` are exported prior to running these
out-of-script initialisation actions, the variables will reflect the state of
the script after its initialisation has performed. In other words, variables
such as [`BUILD_BUILDER`](#option--b-and-build_builder-variable) will reflect
the builder that is about to be used.

The default for this variable is the special character `-`. It will
automatically be resolved to the directory named
[`build-init.d`](./build-init.d/README.md) in the same directory as the compose
file, and the directory [containing](#build_rootdir-variable) the script.

### Option `-c` and `BUILD_CLEANUP_DIR` Variable

Specifies a list of directory paths, separated by the colon `:` sign wherefrom
to find and execute cleanup actions. All exectuable (scripts or programs) in
these directories will automatically be executed once images have been built and
pushed. Cleanup happens in the order of the directories in the path, and in the
alphabetical order of the executable files, within each directory. All variables
starting with `BUILD_` are exported prior to running these out-of-script cleanup
actions, similarily to the [`-i`](#option--i-and-build_init_dir-variable)
option. In addition, cleanup actions can know about built and/or pushed images
through the [`BUILD_IMAGES`](#build_images-variable) variable.

The default for this variable is the special character `-`. It will
automatically be resolved to the directory named
[`build-cleanup.d`](./build-cleanup.d/README.md) in the same directory as the
compose file, and the directory [containing](#build_rootdir-variable) the
script.

### Option `-g` and `BUILD_IGNORE` Variable

Specifies a glob pattern. Executable files from the
[init](#option--i-and-build_init_dir-variable) and
[cleanup](#option--c-and-build_cleanup_dir-variable) directories, which basename
match the pattern will not be executed. The default is to ignore Markdown files
as these would otherwise be deemed executables when running with [WSL].

  [WSL]: https://docs.microsoft.com/en-us/windows/wsl/install

### `BUILD_COMPOSE_BIN` Variable

Specifies how to run `docker-compose`, which also is the default value.

### `BUILD_DOCKER_BIN` Variable

Specifies how to run `docker`, which also is the default value. This makes it,
in theory, possible to use alternatives such as [podman] or [nerdctl].

  [podman]: https://github.com/containers/podman
  [nerdctl]: https://github.com/containerd/nerdctl

### `BUILD_ROOTDIR` Variable

Specifies the root directory for the script, and is automatically initialised to
the root directory of the script. The root directory is used in the default
value for a number of other variables, e.g.
[`BUILD_INIT_DIR`](#option--i-and-build_init_dir-variable) or
[`BUILD_COMPOSE`](#option--f-and-build_compose-variable). `BUILD_ROOTDIR` will
be passed further to out-of-script
[initialisations](#option--i-and-build_init_dir-variable) to help them locating
the triggering script, if necessary.

### `BUILD_DOWNLOADER` Variable

Specifies the command used to download release information from GitHub. When run
the command specified in this variable will be given an additional argument, the
URL to download and it should dump the content of the URL to `stdout` as a
result. When empty, the default, one of `curl` or `wget`, if present, will be
used. When a dash `-`, version checks will be skipped.

### `BUILD_IMAGES` Variable

This variable is computed by the script as it progresses, it cannot be set in
any way. It is passed further to cleanup programs at the end. The variable
contains the space-separated list of images that were built, or the list of
images that were pushed. When images were requested to be built and pushed, only
the list of pushed images will be present.

## GitHub Action

The script doubles as a GitHub Action, use it in a workflow as exemplified
below, provided you have access to `docker`. For a complete list of inputs and
their usage, consult the [`action.yml`](./action.yml) file. The action results
in an output called `images`. `images` contains the list of images that were
built/pushed, one per line.

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Build and Push
        uses: Mitigram/docker-compose-build@main
        with:
          compose: <path-to-compose.yml>
```

## `docker-compose` Shim

In addition, this project contains a [shim](./compose.sh) that is able to
entirely **replace** `docker-compose` `build` (and `push`). The shim can be
installed and called `docker-compose` at the OS level and used to build Docker
images directly with the `docker` client, bypassing `docker-compose` entirely.
This can be usefull to use alternative projects for building Docker images, as
long as they implement a `docker`-compatible CLI interface, e.g. [img] or
[nerdctl]. The shim is capable of translating the standard set of CLI options to
the `build` command of `docker-compose`, to the specific set of options
supported by the `build` command of the `docker`, `img` and `nerdctl` apps.

To install the shim as `docker-compose`, you can make a copy of this project
under `$HOME/.local/share/docker-compose-build` and create a symbolic link to
the `compose.sh` script from `$HOME/.local/bin/docker-compose` (and arrange for
`$HOME/.local/bin` to be first in your `$PATH`).

  [img]: https://github.com/genuinetools/img
  [nerdctl]: https://github.com/containerd/nerdctl

## Future

As [build] has become an optional part of the [compose] specification, this
script could provide a replacement for `docker compose build`, if ever this
functionality was removed (?!). In its current shape, the tool supports the most
common build options, i.e. [context] and [dockerfile], but also build arguments
and labels.

  [build]: https://github.com/compose-spec/compose-spec/blob/master/build.md
  [context]: https://github.com/compose-spec/compose-spec/blob/master/build.md#context-required
  [dockerfile]: https://github.com/compose-spec/compose-spec/blob/master/build.md#dockerfile
