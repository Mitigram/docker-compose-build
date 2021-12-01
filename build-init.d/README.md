# Initialisation Directory

By default any executable present in this directory, or the directory named
similarily, but in the current directory, will be automatically executed once
the [`build.sh`](../build.sh) script has initialised, just before it starts
building and pushing. All variables starting with the prefix `BUILD_` are
exported to the executable. The content of these variables will reflect exactly
how the [`build.sh`](../build.sh) script will behave: for example,
`BUILD_BUILDER` will be the builder that will effectively be used after all
checks have been performed.
