# Library

This directory uses git [`subtree`][subtree] to manage a set of dependencies. At
present, the only dependency is on [`reg-tags`][reg-tags] at present.
**WARNING** `subtree` will make a copy of the foreign project into this
repository, it is up to **you** to manage the lifecycle of that inclusion:
decide when to pull changes, etc. Read this [primer] if in a hurry (or below).

  [subtree]: https://www.atlassian.com/git/tutorials/git-subtree
  [reg-tags]: https://github.com/efrecon/reg-tags
  [primer]: https://gist.github.com/SKempin/b7857a6ff6bddb05717cc17a44091202

## Add a Project

To add a project, from the top-level directory of this repository, run the
following command. This will create a sub-directory called `reg-tags` (from the
`--prefix` option). This CANNOT contain a `.` in the specification.

```shell
git subtree add \
  --prefix lib/reg-tags \
  https://github.com/efrecon/reg-tags.git master --squash
```

## Pull Changes

To pull changes from the foreign project, run the following command from the
top-level directory of this repository.

```shell
git subtree pull \
  --prefix lib/reg-tags \
  https://github.com/efrecon/reg-tags.git master --squash
```
