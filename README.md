# Homebrew SystemCtl

An **experimental** command for integrating Homebrew formulae with Linux' `systemd` init daemon and `systemctl` manager.

## Install

Install using:

```bash
brew tap gergelyrozsas/systemctl
```

## Usage

See usage information using:

```bash
brew systemctl --help
```

## Remarks / Caveats

#### The command aims to be a Linux counterpart of the `brew services` command.

The `brew services` command manages `launchd` init daemon via `launchctl` on macOS, while `brew systemctl` manages `systemd` init daemon via `systemctl` on Linux.
See [Homebrew Services](https://github.com/Homebrew/homebrew-services) for more info about the `brew services` command.

#### The command cannot be used with `sudo`.

Homebrew allows the usage of `sudo` exclusively for the `brew services` command.

#### The command does not support all formulae. Some services may run with side effects or may not run at all.

Homebrew formula service configurations are native to macOS' `launchd`. This implies at least the following things:
- `launchd` service configurations must be converted to `systemd` service configurations. The conversion algorithm that `brew systemctl` uses offers partial support only at the moment.
- The configuration interface of `launchd` and `systemd` services differ, so there might be cases when no one-to-one conversion is available or no conversion is available at all.
- The behavior of `launchd` and `systemd` are at most similar, so the very same service may behave differently on the two daemons - even if the original and converted service configurations are as "identical" as possible. 

## Copyright

Copyright (c) Gergely Rózsás. See [LICENSE.txt](https://github.com/gergelyrozsas/homebrew-systemctl/blob/master/LICENSE.txt) for details.
