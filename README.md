# ssm-scp

An `rsync --rsh` wrapper that tunnels file transfers over [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) — no open ports or SSH keys required.

## How it works

Three phases per transfer:

1. **PTY session** — opens an SSM shell session, configures it, and starts a one-shot Python TCP listener that will `exec` `rsync --server` on the first connection.
2. **Port forward** — opens a second SSM session (`AWS-StartPortForwardingSession`) to create a clean TCP tunnel from a local port to the remote listener.
3. **TCP proxy** — bridges `stdin`/`stdout` through the tunnel so the local `rsync` process sees a standard binary stream.

Compression negotiates automatically: zstd if both sides have rsync ≥ 3.2, zlib otherwise.

## Requirements

| Where  | What |
|--------|------|
| Local  | `aws` CLI + `session-manager-plugin`, `rsync` |
| Remote | SSM agent, IAM instance profile with SSM permissions, `python3`, `rsync` |

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

## Development

```sh
just          # list available recipes
just dev      # fast debug build
just test     # smoke test (--help)
just build    # optimised release binary
just clean    # remove build artefacts
```

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
