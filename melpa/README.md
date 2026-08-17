# MELPA submission

This directory holds the recipe that should be added to the
[melpa/melpa](https://github.com/melpa/melpa) repository, in its
`recipes/` directory, when submitting this package to MELPA.

To submit:

1. Fork `melpa/melpa`.
2. Copy the file `browser-gt` from this directory into the fork's
   `recipes/` directory.
3. Run `make recipes/browser-gt` in the MELPA fork to verify the
   recipe builds.
4. Open a pull request against `melpa/melpa`.

The recipe declares only the `browser-gt*.el` files; the browser
extension under `extension/` (Chrome MV3 and Firefox MV2 builds)
is not distributed through MELPA and must be installed separately.
The README documents this.
