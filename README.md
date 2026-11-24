# ssm-scp

An `rsync --rsh` wrapper that tunnels file transfers over [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) — no open ports or SSH keys required.

## How it works

Three phases per transfer:

1. **PTY session** — opens an SSM shell session, configures it, and starts a one-shot Python TCP listener that runs `rsync --server` on the first connection. The session stays open for the whole transfer.
2. **Port forward** — opens a second SSM session (`AWS-StartPortForwardingSession`) to create a clean TCP tunnel from a local port to the remote listener.
3. **TCP proxy** — bridges `stdin`/`stdout` through the tunnel so the local `rsync` process sees a standard binary stream.

Like `ssh`, ssm-scp passes on the remote `rsync`'s exit status and error text: the listener reports both through the PTY session when the transfer ends, and ssm-scp prints the text on stderr and exits with that status. On exit (also on a signal or a crash) it stops both `aws` processes and their `session-manager-plugin` children.

Compression is negotiated by rsync itself (zstd if both sides have rsync ≥ 3.2, zlib otherwise); ssm-scp does not probe for it and only passes `--compress-level`.

## Requirements

| Where  | What |
|--------|------|
| Local  | `aws` CLI + `session-manager-plugin`, `rsync` |
| Remote | SSM agent, IAM instance profile with SSM permissions, `python3`, `rsync`; passwordless `sudo` when `--sudo` is used (`sudo -n`, so a password prompt fails fast) |

## Local dependencies

```sh
brew install crystal just rsync
brew install --cask session-manager-plugin
just install
```

## Installation

```sh
just install          # builds release binary and installs to /usr/local/bin
```

Or build manually:

```sh
crystal build ssm-scp.cr -o ssm-scp --release
```

## Usage

### Direct (recommended)

```sh
# Upload
ssm-scp [options] LOCAL i-0abc1234:/remote/path

# Download
ssm-scp [options] i-0abc1234:/remote/path LOCAL

# Resolve by EC2 Name tag instead of instance ID
ssm-scp my-server:/remote/path LOCAL
```

### Via rsync `--rsh`

```sh
rsync -e "ssm-scp --region us-west-2" i-0abc1234:/remote/path ./local/
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--region R` | `AWS_REGION` / `us-east-1` | AWS region |
| `--profile P` | `AWS_PROFILE` | AWS CLI profile |
| `--sudo` | off | Run remote `rsync` via `sudo` |
| `--chown USER:GROUP` | | Set owner and group of transferred files (`rsync --chown`; needs `--sudo`) |
| `--chmod MODE` | | Set mode of transferred files (`rsync --chmod`, e.g. `0440` or `F440`) |
| `--rsync-arg ARG` | | Pass `ARG` to `rsync` (repeatable), e.g. `--rsync-arg --dry-run` |
| `--compress-level N` | `6` | zstd/zlib compression level (1–22) |
| `-v`, `--verbose` | off | Verbose output |
| `-V`, `--version` | | Print version and exit |

Valued options also accept the `--opt=value` form: `--region=R`, `--profile=P`,
`--chown=X`, `--chmod=X`, `--rsync-arg=X`, `--compress-level=N`.

`--sudo` runs the remote side as `sudo -n`: the remote user needs passwordless
sudo, otherwise the transfer fails at once instead of waiting for a password.

Unknown options are not dropped silently. In direct mode they are an error
(`unknown option: X`); in `--rsh` mode, where rsync may add its own flags, they are
ignored with a warning on stderr (`ssm-scp: warning: ignoring unknown option(s): ...`).

## Development

```sh
just          # list available recipes
just dev      # fast debug build
just test     # format check + Ameba lint + offline specs (crystal spec)
just spec     # only the specs
just lint     # only Ameba (built into bin/ from the pinned shard)
just smoke    # build and run ./ssm-scp --help
just build    # optimised release binary
just clean    # remove build artefacts
```

The specs under `spec/` are offline: no AWS calls, network, ssh or real SSM
session. They cover the code in `src/` (option parsing, shell escaping, the
resolve cache, rsync flag assembly, PTY/sentinel parsing over pipes). They also
run the remote shell commands in a local `sh`/`bash`, the Python listener in a
local `python3` (TCP echo, SIGHUP survival, accept timeout), and the phase 1
steps against a bash on a real local PTY. `ssm-scp.cr` is the thin script that
wires it to `aws`/`rsync`.

## Copyright & License

Copyright (C) 2026 by MediaAlpha

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
