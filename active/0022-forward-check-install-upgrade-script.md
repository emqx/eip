# Forward compatibility check for install upgrade script (5.0)

## Changelog

* 2022-12-07: @thalesmg Initial draft

## Abstract

This proposes a way to circumvent the limitation that the hot upgrade
installation scripts that are executed cannot be changed after a
package is released, making it impossible to fix bugs or change
upgrade logic.

## Motivation

This section should clearly explain why the functionality proposed by this EIP
is necessary. EIP submissions without sufficient motivation may be rejected
outright.

Currently, when performing a hot upgrade, the scripts that are run are
those from the currently installed EMQX version.  It has a validation
that prevents upgrade between different minor versions.  If we want to
allow an upgrade from, say, 5.0.x to 5.1.y, then the scripts in
already released packages will deny such operation.  Also, if an
upgrade installation script contains a bug in the current, it will
never be able to execute properly without manual patching.

By attempting to execute the scripts from the _target version_, we may
add fixes and new validations to new EMQX versions and have them
executed by older versions.

## Design

### Current upgrade procedure

1. A zip file with a conventional filename format
   (`<relname>-<version>.tar.gz`) is placed in the `releases`
   directory of the currently running EMQX installation.  Typically
   this means `/usr/lib/emqx/releases`.
2. The user runs `emqx {install,upgrade,unpack} <relname>-<version>`.
3. The `emqx` script then calls `install_upgrade.escript` **from the
   currently running version** with some info alongside the desired
   operation and new version.
4. The script then processes the desired operation.

Currently, a versioned copy of `install_upgrade.escript` and `emqx`
are already installed with EMQX in the `bin` directory.  That means
`install_upgrade.escript-<version>` and `emqx-<version>`,
respectively.

### Proposed new procedure

1. First of all, we check if the currently installed and the target
   release profiles match.  For example, if the enterprise edition is
   currently installed and the user attempts to hot-upgrade using a
   community edition package (`emqx-<version>.tar.gz`) or vice-versa,
   the operation should abort.
   - This can be done by checking the `$IS_ENTERPRISE` variable that
     is set in `emqx_vars` and loaded by `bin/emqx` against the
     package filename: `emqx-<version>.tar.gz` for community edition,
     `emqx-enterprise-<version>.tar.gz` for enterprise edition.
2. In the `emqx` script, we parse the desired operation and target
   version and check if scripts called
   `install_upgrade.escript-<target version>` and `emqx-<target
   version>` exist in the `bin` directory.
   - If it does, it means that the target version was already unpacked
     at some point, and we just execute `emqx-<target version>`
     passing it the necessary info.
   - We also need to check inside the `emqx` script if it is the
     `emqx-<target version>` script itself, to avoid an infinite loop.
3. If any such file does not exist, then, without executing the
   currently installed `install_upgrade.escript` file:
   1. We check if the `<relname>-<target version>.tar.gz` file is at
      the expected location (`releases`) and it's readable, bailing
      out otherwise.
   2. We extract _only_ the `install_upgrade.escript-<target version>`
      and `emqx-<target version>` files to the `bin` directory.
   3. Then we just call `emqx-<target version>` with the same
      arguments: `emqx-<target version> {install,unpack,upgrade}
      <target version>`.

## Configuration Changes

No configuration changes needed.

## Backwards Compatibility

Since EMQX 5.0, at the time of writing, has not been tracking appup
changes for hot upgrades, so this change shouldn't pose backwards
compatibility issues.

## Document Changes

The documentation for 5.0 currently doesn't even have a section for
hot upgrades, so it'll need to be ported from 4.x.

## Testing Suggestions

The final implementation must include unit test or common test code. If some
more tests such as integration test or benchmarking test that need to be done
manually, list them here.

## Declined Alternatives

No prior alternatives discussed.
