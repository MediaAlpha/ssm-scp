#!/usr/bin/env crystal
# ssm-scp.cr — rsync --rsh wrapper over AWS SSM Session Manager
#
# Copyright (C) 2026 by MediaAlpha.  All rights reserved.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Build:  crystal build ssm-scp.cr -o ssm-scp --release
#
# Usage (direct):  ssm-scp [opts] HOST:PATH LOCAL
#                  ssm-scp [opts] LOCAL HOST:PATH
# Usage (via rsync --rsh):
#   rsync -e "ssm-scp [--region R] [--profile P] [-v]" \
#         i-0abc1234:/remote/path /local/dst
#
# Architecture — three phases:
#   1. PTY session  : shell setup + starts a Python one-shot TCP listener that
#                     will exec rsync --server once a connection arrives.
#   2. Port forward : second SSM session (AWS-StartPortForwardingSession) builds
#                     a clean TCP tunnel from a local port to the remote listener.
#   3. TCP proxy    : stdin/stdout ↔ TCPSocket — binary-clean by design,
#                     zero PTY line-discipline complications.
#
# Requirements:
#   - aws CLI + session-manager-plugin locally
#   - SSM agent + IAM role on the target instance
#   - python3 + rsync on the remote (standard on Amazon Linux)

require "json"
require "socket"

# ── C bindings (PTY) ──────────────────────────────────────────────────────────

lib LibPTY
  fun posix_openpt(oflag : LibC::Int) : LibC::Int
  fun grantpt(fd : LibC::Int) : LibC::Int
  fun unlockpt(fd : LibC::Int) : LibC::Int
  fun ptsname(fd : LibC::Int) : LibC::Char*
end

{% if flag?(:darwin) %}
  PTY_OPEN_FLAGS = 0x20002
{% else %}
  PTY_OPEN_FLAGS = 0x0402
{% end %}

# ── Constants ─────────────────────────────────────────────────────────────────

VERSION            = {{ `shards version #{__DIR__}`.chomp.stringify }}
SENTINEL_PFX       = "SSMRSH"
CONNECT_TIMEOUT    = 30.0
SETUP_TIMEOUT      = 15.0
PORT_TIMEOUT       = 15.0 # wait for Python to print PORT=
FWD_TIMEOUT        = 20.0 # wait for port-forward tunnel to be ready
ANSI_RE            = /\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/
PROMPT_RE          = /[#$]\s*$/
RESOLVE_CACHE_PATH = Path.home / ".cache" / "scp-ssm" / "resolve.json"
RESOLVE_CACHE_TTL  = 12.hours

# File extensions that are already compressed — rsync should not attempt to
# compress them further.  Covers rsync's own built-in defaults plus modern
# formats (zst, lz4, webp, heic/heif, opus, etc.).
SKIP_COMPRESS = "7z:ace:avi:bz2:deb:dll:dylib:exe:flac:gif:gz:heic:heif:iso:" \
                "jpeg:jpg:lz:lz4:lzma:lzo:m4a:m4v:mkv:mov:mp3:mp4:mpe:mpeg:mpg:" \
                "ogg:opus:png:rar:rpm:rz:so:taz:tb2:tbz:tbz2:tgz:tlz:txz:tzip:" \
                "webm:webp:wmv:xz:z:zip:zst"

# Python 3 one-liner: binds to a free port, prints PORT=XXXX, accepts one
# TCP connection, dup2's it onto fd 0/1, then execvp's rsync --server.
# Uses only single-quoted strings so the whole script can be shell-wrapped
# in double quotes without escaping conflicts.
# signal.SIG_IGN on SIGHUP is inherited across execvp, so rsync survives
# the PTY session closing after the tunnel is established.
PYTHON_LISTENER = "import socket,os,sys,signal;" \
                  "s=socket.socket();" \
                  "s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);" \
                  "s.bind(('127.0.0.1',0));" \
                  "s.listen(1);" \
                  "sys.stdout.write('PORT='+str(s.getsockname()[1])+'\\n');" \
                  "sys.stdout.flush();" \
                  "c,_=s.accept();" \
                  "os.dup2(c.fileno(),0);" \
                  "os.dup2(c.fileno(),1);" \
                  "c.close();" \
                  "s.close();" \
                  "signal.signal(signal.SIGHUP,signal.SIG_IGN);" \
                  "os.execvp(sys.argv[1],sys.argv[1:])"

# ── Helpers ───────────────────────────────────────────────────────────────────

module Cfg
  class_property? verbose = false
end

def die(msg : String) : NoReturn
  STDERR.puts "ssm-scp: #{msg}"
  exit 1
end

def vputs(msg : String)
  STDERR.puts msg if Cfg.verbose?
end

def strip_ansi(s : String) : String
  s.gsub(ANSI_RE, "").gsub("\r\n", "\n").gsub("\r", "\n")
end

def new_token : String
  "#{SENTINEL_PFX}#{Random::Secure.hex(12)}"
end

def shell_escape(s : String) : String
  return "~" if s == "~"
  s.starts_with?("~/") ? "~/" + shell_escape(s[2..]) : "'" + s.gsub("'", "'\\''") + "'"
end

# ── Resolution cache (shared with scp-ssm) ───────────────────────────────────

private def cache_key(name : String, region : String) : String
  "#{name}::#{region}"
end

def cache_lookup(name : String, region : String) : String?
  return nil unless File.exists?(RESOLVE_CACHE_PATH)
  entries = JSON.parse(File.read(RESOLVE_CACHE_PATH))
  entry = entries[cache_key(name, region)]? || return nil
  return nil if Time.utc - Time.parse_iso8601(entry["at"].as_s) > RESOLVE_CACHE_TTL
  entry["id"].as_s
rescue
  nil
end

def cache_store(name : String, region : String, id : String)
  Dir.mkdir_p(RESOLVE_CACHE_PATH.parent.to_s)
  entries = File.exists?(RESOLVE_CACHE_PATH) ? JSON.parse(File.read(RESOLVE_CACHE_PATH)).as_h : Hash(String, JSON::Any).new
  entries[cache_key(name, region)] = JSON.parse({"id" => id, "at" => Time.utc.to_rfc3339}.to_json)
  tmp = "#{RESOLVE_CACHE_PATH}.tmp.#{Process.pid}"
  File.write(tmp, entries.to_json)
  File.rename(tmp, RESOLVE_CACHE_PATH.to_s)
rescue
end

def resolve_target(name : String, region : String, profile : String?) : String
  return name if name.matches?(/^i-[0-9a-f]+$/)
  if cached = cache_lookup(name, region)
    vputs "ssm-scp: '#{name}' resolved from cache -> #{cached}"
    return cached
  end
  STDERR.print "ssm-scp: resolving '#{name}' via EC2 Name tag ..."
  args = ["ec2", "describe-instances",
          "--filters", "Name=tag:Name,Values=#{name}", "Name=instance-state-name,Values=running",
          "--query", "Reservations[].Instances[].InstanceId",
          "--output", "text", "--region", region]
  if profile
    args += ["--profile", profile]
  end
  stdout = IO::Memory.new
  stderr_io = IO::Memory.new
  status = Process.run("aws", args: args, output: stdout, error: stderr_io)
  die "EC2 lookup failed: #{stderr_io.to_s.strip}" unless status.success?
  ids = stdout.to_s.split.reject(&.empty?)
  STDERR.puts " #{ids.first? || "not found"}"
  resolved = case ids.size
             when 0 then die "No running instance with Name='#{name}' in #{region}"
             when 1 then ids.first
             else
               STDERR.puts "ssm-scp: warning: #{ids.size} instances match, using #{ids.first}"
               ids.first
             end
  cache_store(name, region, resolved)
  resolved
end

# Returns true if `rsync --version` output indicates rsync >= 3.2.0 (zstd support).
def rsync_zstd_capable?(version_output : String) : Bool
  return false unless m = version_output.match(/rsync\s+version\s+(\d+)\.(\d+)/)
  major, minor = m[1].to_i, m[2].to_i
  major > 3 || (major == 3 && minor >= 2)
end

# ── PTY read helpers ──────────────────────────────────────────────────────────

def pty_read_chunk(master : IO::FileDescriptor, timeout : Float64) : Bytes
  master.read_timeout = timeout.seconds
  buf = Bytes.new(4096)
  n = master.read(buf)
  n > 0 ? buf[0, n] : Bytes.empty
rescue IO::TimeoutError
  Bytes.empty
rescue IO::EOFError
  die "remote shell closed unexpectedly"
rescue IO::Error
  Bytes.empty
end

def wait_for_prompt(master : IO::FileDescriptor, timeout : Float64) : {Bool, String}
  acc = IO::Memory.new
  deadline = Time.instant + timeout.seconds
  while Time.instant < deadline
    chunk = pty_read_chunk(master, 0.2)
    acc.write(chunk) unless chunk.empty?
    return {true, ""} if PROMPT_RE.match(strip_ansi(acc.to_s))
  end
  {false, strip_ansi(acc.to_s).strip}
end

def read_until_sentinel(master : IO::FileDescriptor, sentinel : String, timeout : Float64) : Int32
  full = IO::Memory.new
  window = sentinel.bytesize + 16
  pattern = /#{Regex.escape(sentinel)}(\d+)/
  deadline = Time.instant + timeout.seconds
  while Time.instant < deadline
    chunk = pty_read_chunk(master, 0.1)
    next if chunk.empty?
    full.write(chunk)
    all = full.to_slice
    tail = String.new(all[{all.size - window, 0}.max..])
    if m = pattern.match(tail)
      return m[1].to_i
    end
  end
  -1
end

# Reads PTY output until PORT=\d+ appears, returns the port number.
def read_remote_port(master : IO::FileDescriptor, timeout : Float64) : Int32?
  acc = IO::Memory.new
  deadline = Time.instant + timeout.seconds
  while Time.instant < deadline
    chunk = pty_read_chunk(master, 0.2)
    acc.write(chunk) unless chunk.empty?
    if m = /PORT=(\d+)/.match(strip_ansi(acc.to_s))
      return m[1].to_i32
    end
  end
  nil
end

# ── Argument parsing ──────────────────────────────────────────────────────────

REMOTE_RE = /^([^:\/][^:]*):(.*)$/

region = ENV["AWS_REGION"]? || ENV["AWS_DEFAULT_REGION"]? || "us-east-1"
profile = ENV["AWS_PROFILE"]?
use_sudo = false
compress_level = 6
chown_spec : String? = nil
chmod_spec : String? = nil
extra_rsync_args = [] of String
argv = ARGV.dup

while (f = argv.first?) && f.starts_with?("-") && f != "--"
  case argv.shift
  when "--region"  then region = argv.shift? || die "missing value for --region"
  when "--profile" then profile = argv.shift? || die "missing value for --profile"
  when "--sudo"    then use_sudo = true
  when "--chown"   then chown_spec = argv.shift? || die "missing value for --chown"
  when "--chmod"   then chmod_spec = argv.shift? || die "missing value for --chmod"
  when "--rsync-arg" then extra_rsync_args << (argv.shift? || die "missing value for --rsync-arg")
  when /^--compress-level=(\d+)$/
    compress_level = $1.to_i
    die "--compress-level must be 1–22" unless compress_level.in?(1..22)
  when "--compress-level"
    compress_level = (argv.shift? || die "missing value for --compress-level").to_i
    die "--compress-level must be 1–22" unless compress_level.in?(1..22)
  when "-v", "--verbose" then Cfg.verbose = true
  when "-l"              then argv.shift?
  when "-V", "--version"
    puts "ssm-scp #{VERSION}"
    exit 0
  when "-h", "--help"
    STDERR.puts "Usage: ssm-scp [--region R] [--profile P] [--sudo] [--compress-level N] [-v] HOST:PATH LOCAL"
    STDERR.puts "       ssm-scp [--region R] [--profile P] [--sudo] [--compress-level N] [-v] LOCAL HOST:PATH"
    STDERR.puts "  --sudo              run remote rsync via sudo (needed for files owned by other users)"
    STDERR.puts "  --chown USER:GROUP  set owner/group of transferred files (rsync --chown; needs --sudo)"
    STDERR.puts "  --chmod MODE        set mode of transferred files (rsync --chmod, e.g. 0440 or F440)"
    STDERR.puts "  --rsync-arg ARG     pass ARG to rsync (repeatable), e.g. --rsync-arg --dry-run"
    STDERR.puts "  --compress-level N  zstd/zlib compression level 1–22 (default: 6)"
    exit 0
  end
end

# Direct invocation: ssm-scp HOST:PATH LOCAL (or LOCAL HOST:PATH)
if argv.size == 2 && (REMOTE_RE.match(argv[0]) || REMOTE_RE.match(argv[1]))
  unless Process.run("which", ["rsync"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    die "rsync not found locally — install rsync first (brew install rsync)"
  end

  local_ver_out = IO::Memory.new
  Process.run("rsync", ["--version"], output: local_ver_out, error: Process::Redirect::Close)
  local_modern = rsync_zstd_capable?(local_ver_out.to_s) # >= 3.2 implies --skip-compress support

  exe = Process.executable_path || PROGRAM_NAME
  rsh_parts = [exe, "--region", region]
  if profile
    rsh_parts += ["--profile", profile]
  end
  rsh_parts << "--sudo" if use_sudo
  rsh_parts << "--compress-level=#{compress_level}"
  rsh_parts << "-v" if Cfg.verbose?
  rsync_flags = ["--progress", "-h", "-z", "--compress-level=#{compress_level}"]
  rsync_flags << "--skip-compress=#{SKIP_COMPRESS}" if local_modern
  rsync_flags << "-v" if Cfg.verbose?
  die "--chown needs --sudo (only root can change ownership on the remote)" if chown_spec && !use_sudo
  rsync_flags << "--chown=#{chown_spec}" if chown_spec
  rsync_flags << "--chmod=#{chmod_spec}" if chmod_spec
  rsync_flags.concat(extra_rsync_args)
  Process.exec("rsync", ["-e", rsh_parts.join(" ")] + rsync_flags + argv)
end

# rsh mode: called by rsync as  ssm-scp [opts] INSTANCE_ID rsync --server ...
die "expected INSTANCE_ID" if argv.empty?
host_arg = argv.shift
instance_id = host_arg.includes?("@") ? host_arg.split("@", 2).last : host_arg

die "expected remote command after INSTANCE_ID" if argv.empty?
# rsync has already escaped these args for a remote shell (it writes `\*`,
# `\ ` etc.), exactly as it does for ssh, which joins them and lets the remote
# shell unescape. Quoting them again would pass the backslashes through
# literally and break `--chown`/`--usermap`/`--groupmap` and paths with spaces.
rsync_args_escaped = argv.join(" ")

# ── Phase 1: PTY session — shell setup + Python listener ─────────────────────

target = resolve_target(instance_id, region, profile)
aws_args = ["ssm", "start-session", "--target", target, "--region", region]
if profile
  aws_args += ["--profile", profile]
end

master_raw = LibPTY.posix_openpt(PTY_OPEN_FLAGS)
die "posix_openpt failed" if master_raw < 0
LibPTY.grantpt(master_raw)
LibPTY.unlockpt(master_raw)
slave_name = String.new(LibPTY.ptsname(master_raw))
slave_raw = LibC.open(slave_name, PTY_OPEN_FLAGS)
die "open slave PTY failed" if slave_raw < 0

attrs = LibC::Termios.new
LibC.tcgetattr(slave_raw, pointerof(attrs))
attrs.c_lflag = attrs.c_lflag & ~typeof(attrs.c_lflag).new(0x8) # ECHO
LibC.tcsetattr(slave_raw, LibC::TCSANOW, pointerof(attrs))

slave_io = IO::FileDescriptor.new(slave_raw)
master = IO::FileDescriptor.new(master_raw)
master.sync = true

pty_process = Process.new("aws", args: aws_args,
  input: slave_io, output: slave_io, error: slave_io)
slave_io.close

STDERR.print "ssm-scp: connecting to #{target} ..."
ok, pty_out = wait_for_prompt(master, CONNECT_TIMEOUT)
unless ok
  STDERR.puts " timed out"
  STDERR.puts pty_out unless pty_out.empty?
  pty_process.terminate rescue nil
  exit 1
end
STDERR.puts " connected"

tok = new_token
STDERR.print "ssm-scp: configuring shell ..."
master.print(
  "stty -echo; export PS1=''; set +o history; " \
  "bind 'set enable-bracketed-paste off' 2>/dev/null; " \
  "printf '%s0\\n' '#{tok}'\n"
)
rc = read_until_sentinel(master, tok, SETUP_TIMEOUT)
die "shell setup failed (rc=#{rc})" unless rc == 0
STDERR.puts " done"

tok_rv = new_token
master.print("command -v rsync >/dev/null 2>&1 && printf '#{tok_rv}0\\n' || printf '#{tok_rv}1\\n'\n")
unless read_until_sentinel(master, tok_rv, SETUP_TIMEOUT) == 0
  master.close rescue nil
  pty_process.terminate rescue nil
  die "rsync not found on remote — install it first (sudo dnf install -y rsync)"
end

# Check and cache remote rsync zstd capability so direct-mode invocations
# can choose the right algorithm without an extra round trip.
# ── Compression algorithm selection ──────────────────────────────────────────
# Check both sides right now, while we already have the PTY session open.
# Local check is instant (no network); remote is one extra sentinel.
# If both are rsync >= 3.2, inject --compress-choice=zstd into the server
# command: the server then only offers zstd, and the local rsync (3.2+) will
# negotiate and select it.  If either side is older we leave -z in place and
# rsync falls back to zlib automatically.

local_ver_io = IO::Memory.new
Process.run("rsync", ["--version"], output: local_ver_io, error: Process::Redirect::Close)
local_zstd = rsync_zstd_capable?(local_ver_io.to_s)

tok_zv = new_token
master.print(
  "rsync --version 2>/dev/null | grep -qE 'rsync +version ([4-9]|3\\.[2-9])' && " \
  "printf '#{tok_zv}0\\n' || printf '#{tok_zv}1\\n'\n"
)
remote_zstd = read_until_sentinel(master, tok_zv, SETUP_TIMEOUT) == 0

use_zstd = local_zstd && remote_zstd
STDERR.puts "ssm-scp: compression: #{use_zstd ? "zstd" : "zlib"} " \
            "level #{compress_level} " \
            "(local #{local_zstd ? "≥3.2" : "<3.2"}, remote #{remote_zstd ? "≥3.2" : "<3.2"})"
# No --compress-choice injection needed: rsync 3.2+ auto-negotiates zstd
# when both sides support it and -z is in use.  Injecting it on the server
# side disrupts rsync's multi-phase negotiation and causes protocol errors.

# Verify the source path(s) exist on the remote before spinning up the
# port-forward and Python listener.  argv has the form:
#   ["rsync", "--server", ..., ".", "path1", "path2", ...]
# Everything after the literal "." is a source path rsync will scan, but only
# for a download (the remote rsync is then the sender, `--sender`).  For an
# upload the remote path is the destination, which may not exist yet.
dot_idx = argv.index(".")
src_paths = dot_idx && argv.includes?("--sender") ? argv[(dot_idx + 1)..] : [] of String

unless src_paths.empty?
  paths_escaped = src_paths.join(" ") # already escaped by rsync, see above
  ls_cmd = use_sudo ? "sudo ls" : "ls"
  tok_chk = new_token
  # rc 0 = accessible, 1 = permission denied, 2 = not found
  master.print(
    "if #{ls_cmd} #{paths_escaped} >/dev/null 2>&1; then printf '#{tok_chk}0\\n'; " \
    "elif #{ls_cmd} #{paths_escaped} 2>&1 | grep -q 'ermission'; then printf '#{tok_chk}1\\n'; " \
    "else printf '#{tok_chk}2\\n'; fi\n"
  )
  rc_chk = read_until_sentinel(master, tok_chk, SETUP_TIMEOUT)
  unless rc_chk == 0
    master.close rescue nil
    pty_process.terminate rescue nil
    hint = rc_chk == 1 ? "(permission denied — try --sudo, or: chmod o+x #{shell_escape(File.dirname(src_paths.first))})" : "(file does not exist on remote)"
    die "cannot access remote path: #{src_paths.join(", ")} #{hint}"
  end
end

# Start the Python listener in background.  It prints PORT=XXXX then blocks on
# accept(); we read the port back through the PTY using read_remote_port.
# SIGHUP is set to SIG_IGN before execvp so rsync survives the PTY closing.
sudo_prefix = use_sudo ? "'sudo' " : ""
STDERR.print "ssm-scp: starting remote listener#{use_sudo ? " (sudo)" : ""} ..."
master.print("python3 -c \"#{PYTHON_LISTENER}\" #{sudo_prefix}#{rsync_args_escaped} 2>/dev/null &\n")
remote_port = read_remote_port(master, PORT_TIMEOUT) || die "timed out waiting for remote rsync port"
STDERR.puts " port #{remote_port}"

# ── Phase 2: SSM port-forwarding session ─────────────────────────────────────

local_port = begin
  tmp = TCPServer.new("127.0.0.1", 0)
  p = tmp.local_address.port
  tmp.close
  p
end

STDERR.print "ssm-scp: port-forwarding #{local_port} → #{remote_port} ..."
params = "{\"portNumber\":[\"#{remote_port}\"],\"localPortNumber\":[\"#{local_port}\"]}"
fwd_args = ["ssm", "start-session",
            "--target", target, "--region", region,
            "--document-name", "AWS-StartPortForwardingSession",
            "--parameters", params]
if profile
  fwd_args += ["--profile", profile]
end

null_r = File.open(File::NULL, "r")
null_w = File.open(File::NULL, "w")
fwd_process = Process.new("aws", args: fwd_args,
  input: null_r, output: null_w, error: null_w)
null_r.close
null_w.close

sock : TCPSocket? = nil
(FWD_TIMEOUT / 0.5).to_i.times do
  sleep 0.5.seconds
  begin
    sock = TCPSocket.new("127.0.0.1", local_port)
    break
  rescue
  end
end
die "port-forward tunnel did not establish within #{FWD_TIMEOUT.to_i}s" unless sock
STDERR.puts " ready"

# Python has accepted the connection and exec'd rsync; PTY session is no longer needed.
master.close rescue nil
pty_process.terminate rescue nil

# ── Phase 3: TCP proxy ────────────────────────────────────────────────────────

tcp = sock
tcp.sync = true

# Crystal initialises STDIN/STDOUT as blocking=true; set non-blocking so both
# proxy fibers use the event loop instead of stalling the OS thread.
IO::FileDescriptor.set_blocking(STDIN.fd, false)
IO::FileDescriptor.set_blocking(STDOUT.fd, false)
STDOUT.sync = true

done = Channel(Nil).new(2)

spawn do
  buf = Bytes.new(65536)
  loop do
    n = tcp.read(buf)
    break if n <= 0
    STDOUT.write(buf[0, n])
    STDOUT.flush
  end
rescue
ensure
  STDOUT.close rescue nil # EOF to local rsync's stdin → rsync exits
  STDIN.close rescue nil  # unblocks Fiber 2 if it is stuck on STDIN.read
  done.send(nil)
end

spawn do
  buf = Bytes.new(65536)
  loop do
    n = STDIN.read(buf)
    break if n <= 0
    tcp.write(buf[0, n])
  end
rescue
ensure
  tcp.close rescue nil # EOF to remote rsync, also unblocks Fiber 1's tcp.read
  done.send(nil)
end

2.times { done.receive }
tcp.close rescue nil
fwd_process.terminate rescue nil
