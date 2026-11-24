# ssm-scp

An `rsync --rsh` wrapper that tunnels file transfers over [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) — no open ports or SSH keys required.

## How it works

Three phases per transfer:

1. **PTY session** — opens an SSM shell session, configures it (it starts in `$HOME`, like `ssh`), and starts a one-shot Python TCP listener that runs `rsync --server` once a client has sent the per-run auth token. The session stays open for the whole transfer; ssm-scp types a no-op newline into it every 60 s so SSM's idle timeout cannot end it, and `rsync` itself runs in its own session on the remote.
2. **Port forward** — opens a second SSM session (`AWS-StartPortForwardingSession`) to create a clean TCP tunnel from a local port to the remote listener.
3. **TCP proxy** — sends the auth token first, then bridges `stdin`/`stdout` through the tunnel so the local `rsync` process sees a standard binary stream. After local EOF the socket is closed for good if the remote side has not closed within 30 s.

Like `ssh`, ssm-scp passes on the remote `rsync`'s exit status and error text: the listener reports both through the PTY session when the transfer ends, and ssm-scp prints the text on stderr and exits with that status. On exit (also on `SIGINT`, `SIGTERM`, `SIGHUP`, `SIGUSR1` — which rsync sends its rsh child on Ctrl-C or an error — `SIGUSR2`, `SIGQUIT`, or a crash) it closes the tunnel, waits (after a signal) for the remote rsync to end so it removes its temporary file, says `exit` to the remote shell, and stops both `aws` processes and their `session-manager-plugin` children.

Every command line sent to the remote shell is base64-encoded (`eval "$(printf %s ... | base64 -d)"`), so paths with tabs, quotes, `é` or control characters arrive byte for byte. Only the first setup line is plain ASCII. The listener's auth token (a second random secret, separate from the frame token that is visible in the remote `ps`) is passed in its environment, never on a command line; a client that does not send it first gets exit status 126 and `rsync` is not started.

Compression is negotiated by rsync itself (zstd if both sides have rsync ≥ 3.2, zlib otherwise); ssm-scp does not probe for it and only passes `--compress-level`.

## Requirements

| Where  | What |
|--------|------|
| Local  | `aws` CLI + `session-manager-plugin`, `rsync` |
| Remote | SSM agent, IAM instance profile with SSM permissions, `python3`, `rsync`, `base64` (coreutils); passwordless `sudo` when `--sudo` is used (`sudo -n`, so a password prompt fails fast) |

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
# Upload (one or more sources)
ssm-scp [options] LOCAL... i-0abc1234:/remote/path

# Download (one or more sources)
ssm-scp [options] i-0abc1234:/remote/path... LOCAL

# Relative remote paths start in the remote user's home, like ssh
ssm-scp i-0abc1234:notes.txt LOCAL

# Resolve by EC2 Name tag instead of instance ID
ssm-scp my-server:/remote/path LOCAL

# A file name that starts with a dash: put `--` before the paths
ssm-scp -- -odd-name.txt i-0abc1234:/tmp/
```

### Via rsync `--rsh`

```sh
rsync -e "ssm-scp --region us-west-2" i-0abc1234:/remote/path ./local/
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--region R` | `AWS_REGION`, then `AWS_DEFAULT_REGION`, else none | AWS region. When none is set, `--region` is not passed to `aws`, so the CLI uses the selected profile's region (`~/.aws/config`) |
| `--profile P` | `AWS_PROFILE` | AWS CLI profile |
| `--sudo` | off | Run remote `rsync` via `sudo` |
| `--chown USER:GROUP` | | Set owner and group of transferred files (`rsync --chown`; needs `--sudo`) |
| `--chmod MODE` | | Set mode of transferred files (`rsync --chmod`, e.g. `0440` or `F440`) |
| `--rsync-arg ARG` | | Pass `ARG` to `rsync` (repeatable), e.g. `--rsync-arg --dry-run` |
| `--compress-level N` | `6` | zstd/zlib compression level (1–22) |
| `-v`, `--verbose` | off | Verbose output |
| `-V`, `--version` | | Print version and exit |
| `-h`, `--help` | | Print help and exit |

Valued options also accept the `--opt=value` form: `--region=R`, `--profile=P`,
`--chown=X`, `--chmod=X`, `--rsync-arg=X`, `--compress-level=N`.

`--sudo` runs the remote side as `sudo -n`: the remote user needs passwordless
sudo, otherwise the transfer fails at once instead of waiting for a password.

Direct mode is used when there are at least two positional arguments, one of them `HOST:PATH`, and no `--server` word (that one marks the call from `rsync -e`). The positional arguments are handed to `rsync` after `--`.

A Name tag is looked up in EC2 (`running` instances) and the id is cached for 12 hours in `~/.cache/scp-ssm/resolve.json` under `name::region[::profile]` (`name::default[::profile]` when no region is set). Names with `,`, `*` or `?` are refused (EC2 filters give them a special meaning). When several instances carry the name, ssm-scp warns, uses the first and does not cache the choice.

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
run the remote shell commands in a local `sh`/`bash`/`dash`, the Python listener
in a local `python3` (TCP echo, auth token, own session, accept timeout), and
the phase 1 steps against bash (with and without readline) and dash on a real
local PTY.

`spec/e2e_spec.cr` runs `ssm-scp.cr` itself (compiled once per run) against a
fake `aws` on `PATH` (`spec/support/bin/aws`: a local interactive bash is the
"remote" shell, `spec/support/fwd.py` is the port forward) and a real local
`rsync`: upload, download, exit status propagation, several sources, odd file
names, relative paths, regions, name resolution, signal cleanup. It is skipped
when `python3`, `rsync`, `bash`, `base64` or `crystal` is missing.

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
