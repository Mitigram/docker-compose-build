# docker-compose-build

Using `docker-compose` in dev, but a more complex orchestrator in production?
This script considers the `docker-compose.yml` file as the single point of truth
for build information and will supplement/replace `docker compose build` with
`docker build` in order to:

+ Push the resulting image(s) to their registries.
+ Replace the registry settings from the compose file with another one, if
  necessary.
+ Retag, or add tags to the images that will be built and/or pushed.

This script has sane defaults. If `docker-compose` is installed, its default
behaviour is to build all or some of the services that are pointed at by the
`docker-compose.yml` file in the current directory. When operations such as
pushing, retagging or changing the destination registry are requested, the
script will actively read the content of the `docker-compose.yml` and pick the
necessary information from there. At the time of writing, this will work best
when the `services` section is last in the file.

The result of this script is a list of the Docker images that were built (or
[pushed](#flag--p-and-build_push-variable), depending) on `stdout`, one per
line. This is to facilitate automation. All other output (logging, output of
`docker` or `docker-compose`, etc.) is redirected to `stderr`.

## Example

### Compose Example

All examples are based on the following compose skeleton:

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
various steps that it performs more verbosedly on the stderr.

### Flag `-p` and `BUILD_PUSH` Variable

When the flag is given or the variable set to `1`, the images specified by the
compose file will also be pushed to their respective registries, once building
has finished. Your local `docker` client must have enough credentials to access
the remote registry.

### Option `-f` and `BUILD_COMPOSE` Variable

Specifies the location of the compose file to use. The default is to look for a
file called `docker-compose.yml` first in the current directory, then in the
same directory as the script is located at.

### Option `-b` and `BUILD_BUILDER` Variable

Specifies the builder to use, can be one of:

+ `compose` (the default): will try hard to use compose, but will revert to the
  `auto` builder (see below) when `docker-compose` is not installed.
+ `auto`: will pick the best of the new `buildx` or old-style `docker build`,
  depending on which is available, and in that order, i.e. `buildx` preferred.
+ `buildx`: will use the new `buildx` for building. This requires the `buildx`
  Docker plugin to be available and properly installed.
+ `docker` or `build`: will use the old-style `docker build` command.

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

Specified an alternative registry to use instead of the one specified as part of
the compose file. When no registry is given, the default, the registry will be
the one from the compose file.

### Option `-a` and `BUILD_AGE` Variable

Specifies the maximum age of the image since creation to decide whether it
should be pushed or not. This is a safety measure to avoid pushing junk images
that would have been built in the past. The default of `1200` seconds should
work in most cases, but any negative value will turn this check off, meaning
that all relevant images will be pushed, disregarding their age.

### `BUILD_COMPOSE_BIN` Variable

Specifies how to run `docker-compose`, which also is the default value.

### `BUILD_DOCKER_BIN` Variable

Specifies how to run `docker`, which also is the default value. This makes it,
in theory, possible to use alternatives such as [podman] or [nerdctl].

  [podman]: https://github.com/containers/podman
  [nerdctl]: https://github.com/containerd/nerdctl
