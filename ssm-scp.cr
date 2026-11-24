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
#   - passwordless sudo on the remote when --sudo is used (sudo -n)

require "json"
require "socket"
require "./src/ssm_scp"

# ── Constants ─────────────────────────────────────────────────────────────────

VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}

# ── Helpers ───────────────────────────────────────────────────────────────────

module Cfg
  class_property? verbose = false
end

# Child processes to stop when we bail out through `die`.
module Cleanup
  @@procs = [] of Process

  def self.register(proc : Process) : Process
    @@procs << proc
    proc
  end

  def self.run : Nil
    @@procs.each do |proc|
      proc.terminate
    rescue
      nil
    end
  end
end

# Stop our child processes and exit with the conventional 128+signal code.
{% for sig in [:INT, :TERM, :HUP] %}
  Signal::{{ sig.id }}.trap do
    Cleanup.run
    exit 128 + Signal::{{ sig.id }}.value
  end
{% end %}

def die(msg : String) : NoReturn
  STDERR.puts "ssm-scp: #{msg}"
  Cleanup.run
  exit 1
end

# Turns errors raised by the testable helpers in src/ into `die`.
def guarded(&)
  yield
rescue ex : SsmScp::Error
  die ex.message.to_s
end

def vputs(msg : String)
  STDERR.puts msg if Cfg.verbose?
end

# ── Resolution cache (shared with scp-ssm) ───────────────────────────────────

RESOLVE_CACHE = SsmScp::ResolveCache.new

# Returns {instance id, true if it came from the cache}.
def resolve_target(name : String, region : String, profile : String?) : {String, Bool}
  return {name, false} if SsmScp::Resolve.instance_id?(name)
  if cached = RESOLVE_CACHE.lookup(name, region, profile)
    vputs "ssm-scp: '#{name}' resolved from cache -> #{cached}"
    return {cached, true}
  end
  STDERR.print "ssm-scp: resolving '#{name}' via EC2 Name tag ..."
  args = SsmScp::Resolve.ec2_lookup_args(name, region, profile)
  stdout = IO::Memory.new
  stderr_io = IO::Memory.new
  status = Process.run("aws", args: args, output: stdout, error: stderr_io)
  die "EC2 lookup failed: #{stderr_io.to_s.strip}" unless status.success?
  ids = SsmScp::Resolve.parse_ids(stdout.to_s)
  STDERR.puts " #{ids.first? || "not found"}"
  resolved = case ids.size
             when 0 then die "No running instance with Name='#{name}' in #{region}"
             when 1 then ids.first
             else
               STDERR.puts "ssm-scp: warning: #{ids.size} instances match, using #{ids.first}"
               ids.first
             end
  RESOLVE_CACHE.store(name, region, resolved, profile)
  {resolved, false}
end

# ── Argument parsing ──────────────────────────────────────────────────────────

opts = guarded { SsmScp::Options.parse(ARGV) }

case opts.action
when .version?
  puts "ssm-scp #{VERSION}"
  exit 0
when .help?
  SsmScp::Options.help_lines.each { |line| STDERR.puts line }
  exit 0
end

region = opts.region
profile = opts.profile
use_sudo = opts.sudo?
compress_level = opts.compress_level
Cfg.verbose = opts.verbose?
argv = opts.rest

# Direct invocation: ssm-scp HOST:PATH LOCAL (or LOCAL HOST:PATH)
if SsmScp::Resolve.direct_mode?(argv)
  die "unknown option: #{opts.unknown.join(", ")}" unless opts.unknown.empty?
  unless Process.find_executable("rsync")
    die "rsync not found locally — install rsync first (brew install rsync)"
  end

  local_ver_out = IO::Memory.new
  Process.run("rsync", ["--version"], output: local_ver_out, error: Process::Redirect::Close)
  local_modern = rsync_zstd_capable?(local_ver_out.to_s) # >= 3.2 implies --skip-compress support

  exe = Process.executable_path || PROGRAM_NAME
  Process.exec("rsync", guarded { opts.rsync_argv(exe, local_modern, argv) })
end

# rsh mode: called by rsync as  ssm-scp [opts] INSTANCE_ID rsync --server ...
unless opts.unknown.empty?
  STDERR.puts "ssm-scp: warning: ignoring unknown option(s): #{opts.unknown.join(", ")}"
end
die "expected INSTANCE_ID" if argv.empty?
instance_id = SsmScp::Resolve.host_from_arg(argv.shift)

die "expected remote command after INSTANCE_ID" if argv.empty?
server_args = SsmScp::ServerArgs.new(argv)
# Already escaped by rsync for a remote shell; see SsmScp::ServerArgs.
rsync_args_escaped = server_args.escaped

# ── Phase 1: PTY session — shell setup + Python listener ─────────────────────

target, from_cache = resolve_target(instance_id, region, profile)
aws_args = ["ssm", "start-session", "--target", target, "--region", region]
if profile
  aws_args += ["--profile", profile]
end

master, slave_io = guarded { SsmScp.open_pty }

pty_process = Cleanup.register(Process.new("aws", args: aws_args,
  input: slave_io, output: slave_io, error: slave_io))
slave_io.close

STDERR.print "ssm-scp: connecting to #{target} ..."
ok, pty_out = begin
  wait_for_prompt(master, CONNECT_TIMEOUT)
rescue ex : SsmScp::Error
  {false, ex.message.to_s}
end
unless ok
  STDERR.puts " failed"
  STDERR.puts pty_out unless pty_out.empty?
  if from_cache
    RESOLVE_CACHE.evict(instance_id, region, profile)
    STDERR.puts "ssm-scp: cached id may be stale, removed from cache; retry"
  end
  Cleanup.run
  exit 1
end
STDERR.puts " connected"

tok = new_token
STDERR.print "ssm-scp: checking remote shell, rsync and python3 ..."
master.print(SsmScp::Remote.preflight_command(tok))
case rc = guarded { read_until_sentinel(master, tok, SETUP_TIMEOUT) }
when  0 then STDERR.puts " done"
when  1 then die "rsync not found on remote — install it first (sudo dnf install -y rsync)"
when  2 then die "python3 not found on remote — install it first (sudo dnf install -y python3)"
when -1 then die "timed out waiting for the remote shell setup (no answer within #{SETUP_TIMEOUT.to_i}s)"
else         die "remote shell setup failed (rc=#{rc})"
end

vputs "ssm-scp: compression level #{compress_level} (rsync negotiates zstd/zlib)"

# Verify the source path(s) exist on the remote before spinning up the
# port-forward and Python listener.  argv has the form:
#   ["rsync", "--server", ..., ".", "path1", "path2", ...]
# Everything after the literal "." is a source path rsync will scan, but only
# for a download (the remote rsync is then the sender, `--sender`).  For an
# upload the remote path is the destination, which may not exist yet.
src_paths = server_args.src_paths

unless src_paths.empty?
  paths_escaped = src_paths.join(" ") # already escaped by rsync, see above
  tok_chk = new_token
  master.print(SsmScp::Remote.check_command(paths_escaped, use_sudo, tok_chk))
  rc_chk = guarded { read_until_sentinel(master, tok_chk, SETUP_TIMEOUT) }
  unless rc_chk == 0
    die SsmScp::Remote.check_failure(rc_chk, src_paths)
  end
end

# Start the Python listener in background.  It prints PORT=XXXX then blocks on
# accept(); we read the port back through the PTY using read_remote_port.
# SIGHUP is set to SIG_IGN before execvp so rsync survives the PTY closing.
STDERR.print "ssm-scp: starting remote listener#{use_sudo ? " (sudo)" : ""} ..."
master.print(SsmScp::Remote.listener_command(use_sudo, rsync_args_escaped))
remote_port = guarded { read_remote_port(master, PORT_TIMEOUT) } || die "timed out waiting for remote rsync port"
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
fwd_process = Cleanup.register(Process.new("aws", args: fwd_args,
  input: null_r, output: null_w, error: Process::Redirect::Pipe))
null_r.close
null_w.close

# Keep what the port-forward process says on stderr, to show if it fails.
fwd_err = IO::Memory.new
fwd_err_done = Channel(Nil).new
spawn do
  IO.copy(fwd_process.error, fwd_err)
rescue
ensure
  fwd_err_done.send(nil)
end

def fwd_stderr(io : IO::Memory) : String
  text = io.to_s.strip
  text.empty? ? "" : "\n#{text}"
end

sock : TCPSocket? = nil
(FWD_TIMEOUT / 0.5).to_i.times do
  begin
    sock = TCPSocket.new("127.0.0.1", local_port)
    break
  rescue
  end
  if fwd_process.terminated?
    # Let the stderr reader see EOF so the message is complete.
    select
    when fwd_err_done.receive
    when timeout(1.second)
    end
    die "port-forward session ended before the tunnel was ready#{fwd_stderr(fwd_err)}"
  end
  sleep 0.5.seconds
end
die "port-forward tunnel did not establish within #{FWD_TIMEOUT.to_i}s#{fwd_stderr(fwd_err)}" unless sock
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
  begin
    loop do
      n = STDIN.read(buf)
      break if n <= 0
      tcp.write(buf[0, n])
    end
    # Local EOF: half-close so remote -> local data keeps flowing; Fiber 1
    # ends on the remote's EOF.
    tcp.close_write rescue nil
  rescue
    # e.g. a failed write: close fully so Fiber 1's tcp.read is unblocked.
    tcp.close rescue nil
  end
  done.send(nil)
end

2.times { done.receive }
tcp.close rescue nil
Cleanup.run
