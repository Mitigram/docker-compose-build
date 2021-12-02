# Cleanup Directory

By default any executable present in this directory, or the directory named
similarily, but in the current directory where the script is started from, will
be automatically executed once the [`build.sh`](../build.sh) script has build
and/or pushed all images. All variables starting with the prefix `BUILD_` are
exported to the executables. The content of these variables will reflect exactly
how the [`build.sh`](../build.sh) script has behaved: for example,
`BUILD_BUILDER` will be the builder that will effectively be used after all
checks have been performed.

A variable called `BUILD_IMAGES` is also passed further to cleanup programs. The
variable contains the space-separated list of images that were built, or the
list of images that were pushed. When images were requested to be built and
pushed, only the list of pushed images will be present.
