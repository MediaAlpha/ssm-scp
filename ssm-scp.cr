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
# Usage (direct):  ssm-scp [opts] HOST:PATH... LOCAL
#                  ssm-scp [opts] LOCAL... HOST:PATH
# Usage (via rsync --rsh):
#   rsync -e "ssm-scp [--region R] [--profile P] [-v]" \
#         i-0abc1234:/remote/path /local/dst
#
# Architecture — three phases:
#   1. PTY session  : shell setup + starts a Python one-shot TCP listener that
#                     will run rsync --server once a client has sent the
#                     per-run auth token over the connection.
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

# Child processes to stop when we leave, however we leave.  Each `aws`
# process runs `session-manager-plugin` as its own child, so the whole tree
# is stopped (SIGTERM, then SIGKILL for what ignores it).  Idempotent, and
# safe against a second caller (a signal handler, `die`, at_exit) arriving
# while a cleanup is under way: it waits for that one, and a process is only
# taken off the list once it has been through the full TERM + KILL pass.
#
# Killing the plugin does not close the tunnel on the instance (the SSM agent
# keeps the connection to the remote listener open, so rsync there would wait
# forever and leave its temporary file), and it does not end the shell
# session either.  So, in this order:
#   1. close our end of the tunnel socket (the plugin passes the close on);
#      after a signal, wait until the remote listener reports that rsync has
#      ended (it has then removed its temporary file);
#   2. stop the port-forward, newest process first;
#   3. say `exit` to the remote shell and give its session time to end;
#   4. TERM/KILL whatever is left.
module Cleanup
  @@procs = [] of {Process, IO?}
  @@sock : TCPSocket?
  @@pty : IO::FileDescriptor?
  @@token : String?
  @@running = false
  class_property? stopping = false

  EXIT_GRACE = 2.seconds

  # How long, after a signal, to wait for the remote rsync to end once the
  # tunnel is closed.
  def self.remote_wait : Float64
    ENV["SSM_SCP_REMOTE_WAIT"]?.try(&.to_f?) || 8.0 # hidden knob for the specs
  end

  # `farewell`: the PTY master of a shell session; `exit` is typed into it
  # before the process is killed.
  def self.register(proc : Process, farewell : IO? = nil) : Process
    @@procs << {proc, farewell}
    proc
  end

  # The tunnel socket, and where the remote listener's result frame (marked
  # with `token`) will show up.
  def self.tunnel(sock : TCPSocket, pty : IO::FileDescriptor, token : String) : Nil
    @@sock = sock
    @@pty = pty
    @@token = token
  end

  def self.run : Nil
    if @@running
      while @@running
        sleep 0.05.seconds
      end
      return
    end
    @@running = true
    begin
      close_tunnel
      @@procs.dup.reverse_each do |(proc, farewell)|
        stop(proc, farewell)
        @@procs.delete({proc, farewell})
      end
    ensure
      @@running = false
    end
  end

  private def self.close_tunnel : Nil
    sock = @@sock
    @@sock = nil
    return if sock.nil? || sock.closed?
    sock.close rescue nil
    # Only when interrupted mid-transfer: nobody else is reading the PTY then.
    if stopping? && (pty = @@pty) && (token = @@token)
      read_remote_result(pty, token, remote_wait) rescue nil
    end
  end

  private def self.stop(proc : Process, farewell : IO?) : Nil
    return unless proc.exists?
    if io = farewell
      io.print("exit\n") rescue nil
      deadline = Time.instant + EXIT_GRACE
      while proc.exists? && Time.instant < deadline
        sleep 0.05.seconds
      end
    end
    if proc.exists?
      SsmScp::ProcTree.kill_tree(proc.pid) { |pid| pid == proc.pid ? proc.exists? : Process.exists?(pid) }
    end
  rescue
    nil
  end
end

# Also covers crashes (an uncaught exception, e.g. EPIPE on STDERR when our
# output is piped into `head`) and every `exit`.
at_exit { Cleanup.run }

# By default Crystal calls libc `exit 141` on EPIPE for stdout/stderr, which
# skips `at_exit` and would leave the aws processes running.  Raise instead.
STDOUT.exit_on_broken_pipe = false
STDERR.exit_on_broken_pipe = false

# Stop our child processes and exit with the conventional 128+signal code.
# USR1 matters most: rsync sends SIGUSR1 to its rsh child on Ctrl-C or on an
# error.  A signal that arrives while the first one is being handled is
# ignored; the first handler finishes the cleanup and exits.
{% for sig in [:INT, :TERM, :HUP, :USR1, :USR2, :QUIT] %}
  Signal::{{ sig.id }}.trap do
    next if Cleanup.stopping?
    Cleanup.stopping = true
    Cleanup.run
    exit 128 + Signal::{{ sig.id }}.value
  end
{% end %}

# A progress line ("... ") that is still open when an error is printed gets
# finished first, so the error starts on a line of its own.
module Progress
  class_property? open = false

  def self.start(text : String) : Nil
    STDERR.print text
    self.open = true
  end

  def self.finish(text : String) : Nil
    STDERR.puts text
    self.open = false
  end
end

def die(msg : String) : NoReturn
  STDERR.puts if Progress.open?
  Progress.open = false
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

# A hidden knob for the specs: seconds, overrides the default.
def env_seconds(name : String, default : Float64) : Time::Span
  (ENV[name]?.try(&.to_f?) || default).seconds
end

def require_aws : Nil
  return if Process.find_executable("aws")
  die "aws CLI not found — install it (brew install awscli) and session-manager-plugin"
end

# ── Resolution cache (shared with scp-ssm) ───────────────────────────────────

RESOLVE_CACHE = SsmScp::ResolveCache.new

# Returns {instance id, true if it came from the cache}.
def resolve_target(name : String, region : String?, profile : String?) : {String, Bool}
  return {name, false} if SsmScp::Resolve.instance_id?(name)
  guarded { SsmScp::Resolve.check_name!(name) }
  if cached = RESOLVE_CACHE.lookup(name, region, profile)
    vputs "ssm-scp: '#{name}' resolved from cache -> #{cached}"
    return {cached, true}
  end
  Progress.start "ssm-scp: resolving '#{name}' via EC2 Name tag ..."
  args = SsmScp::Resolve.ec2_lookup_args(name, region, profile)
  stdout = IO::Memory.new
  stderr_io = IO::Memory.new
  status = Process.run("aws", args: args, output: stdout, error: stderr_io)
  die "EC2 lookup failed: #{stderr_io.to_s.strip}" unless status.success?
  ids = SsmScp::Resolve.parse_ids(stdout.to_s)
  Progress.finish " #{ids.first? || "not found"}"
  case ids.size
  when 0
    die "No running instance with Name='#{name}'#{region ? " in #{region}" : ""}"
  when 1
    RESOLVE_CACHE.store(name, region, ids.first, profile)
    {ids.first, false}
  else
    # Which one is meant is a guess, so do not make it stick.
    STDERR.puts "ssm-scp: warning: #{ids.size} instances match '#{name}' (#{ids.join(", ")}), " \
                "using #{ids.first}; not cached, use an instance id to be sure"
    {ids.first, false}
  end
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

# Direct invocation: ssm-scp HOST:PATH... LOCAL (or LOCAL... HOST:PATH)
if SsmScp::Resolve.direct_mode?(argv)
  die "unknown option: #{opts.unknown.join(", ")}" unless opts.unknown.empty?
  require_aws
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

require_aws

# ── Phase 1: PTY session — shell setup + Python listener ─────────────────────

target, from_cache = resolve_target(instance_id, region, profile)
aws_args = SsmScp::Resolve.session_args(target, region, profile)

master, slave_io = guarded { SsmScp.open_pty }

Cleanup.register(Process.new("aws", args: aws_args,
  input: slave_io, output: slave_io, error: slave_io), master)
slave_io.close

Progress.start "ssm-scp: connecting to #{target} ..."
ok, pty_out = begin
  wait_for_prompt(master, CONNECT_TIMEOUT)
rescue ex : SsmScp::Error
  {false, ex.message.to_s}
end
unless ok
  Progress.finish " failed"
  STDERR.puts pty_out unless pty_out.empty?
  if from_cache
    RESOLVE_CACHE.evict(instance_id, region, profile)
    STDERR.puts "ssm-scp: cached id may be stale, removed from cache; retry"
  end
  Cleanup.run
  exit 1
end
Progress.finish " connected"

tok = new_token
Progress.start "ssm-scp: checking remote shell, rsync, python3 and base64 ..."
# Plain text: a fixed ASCII line that has to work before we know that base64
# exists.  Everything after it is sent through SsmScp::Remote.wrap.
master.print(SsmScp::Remote.preflight_command(tok))
case rc = guarded { read_until_sentinel(master, tok, SETUP_TIMEOUT) }
when  0 then Progress.finish " done"
when  1 then die "rsync not found on remote — install it first (sudo dnf install -y rsync)"
when  2 then die "python3 not found on remote — install it first (sudo dnf install -y python3)"
when  3 then die "base64 not found on remote — install it first (sudo dnf install -y coreutils)"
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
  SsmScp::Remote.send(master, SsmScp::Remote.wrap(SsmScp::Remote.check_command(paths_escaped, use_sudo, tok_chk)))
  rc_chk, failures = guarded { read_check_result(master, tok_chk, SETUP_TIMEOUT) }
  unless rc_chk == 0
    failed = failures.select { |(code, _)| code == rc_chk }.map { |(_, path)| path }
    die SsmScp::Remote.check_failure(rc_chk, src_paths, use_sudo, failed)
  end
end

# Start the Python listener in background.  It prints PORT=XXXX then blocks on
# accept(); we read the port back through the PTY using read_remote_port.
# `auth` is a second secret, separate from the frame token `run_tok`: the
# frame token is in the listener's argv (visible in `ps` to other users of the
# instance), the auth token is passed in its environment and must be the
# first bytes sent over the tunnel, or rsync is not started.
Progress.start "ssm-scp: starting remote listener#{use_sudo ? " (sudo)" : ""} ..."
run_tok = new_token
auth = Random::Secure.hex(16)
SsmScp::Remote.send(master, SsmScp::Remote.wrap(SsmScp::Remote.listener_command(use_sudo, rsync_args_escaped, run_tok, auth)))
remote_port = guarded { read_remote_port(master, PORT_TIMEOUT) } || die "timed out waiting for remote rsync port"
Progress.finish " port #{remote_port}"

# ── Phase 2: SSM port-forwarding session ─────────────────────────────────────

local_port = begin
  tmp = TCPServer.new("127.0.0.1", 0)
  p = tmp.local_address.port
  tmp.close
  p
end

Progress.start "ssm-scp: port-forwarding #{local_port} → #{remote_port} ..."
fwd_args = SsmScp::Resolve.forward_args(target, local_port, remote_port, region, profile)

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
Progress.finish " ready"

# The PTY session stays open: the listener reports rsync's stderr and exit
# code through it once the transfer is over.

# ── Phase 3: TCP proxy ────────────────────────────────────────────────────────

tcp = sock
tcp.sync = true
Cleanup.tunnel(tcp, master, run_tok)

# The listener wants the auth token before it starts rsync.
begin
  tcp.write(auth.to_slice)
rescue ex
  die "could not send the auth token to the remote listener: #{ex.message}"
end

# Crystal initialises STDIN/STDOUT as blocking=true; set non-blocking so both
# proxy fibers use the event loop instead of stalling the OS thread.
IO::FileDescriptor.set_blocking(STDIN.fd, false)
IO::FileDescriptor.set_blocking(STDOUT.fd, false)
STDOUT.sync = true

# While the transfer runs the PTY session is otherwise idle; a no-op line now
# and then keeps SSM's idle timeout from ending it (and with it the result).
keepalive = SsmScp::Keepalive.start(master, env_seconds("SSM_SCP_KEEPALIVE", KEEPALIVE_INTERVAL))

done = Channel(Nil).new(2)
remote_closed = Channel(Nil).new

spawn do
  buf = Bytes.new(65536)
  loop do
    n = tcp.read(buf)
    break if n <= 0
    STDOUT.write(buf[0, n])
  end
rescue
ensure
  remote_closed.close
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
    # ends on the remote's EOF.  If the remote does not close within a while,
    # close the socket fully rather than hang forever.
    tcp.close_write rescue nil
    SsmScp.close_if_remote_stays_open(tcp, remote_closed, env_seconds("SSM_SCP_HALF_CLOSE_TIMEOUT", HALF_CLOSE_TIMEOUT))
  rescue
    # e.g. a failed write: close fully so Fiber 1's tcp.read is unblocked.
    tcp.close rescue nil
  end
  done.send(nil)
end

2.times { done.receive }
keepalive.stop
tcp.close rescue nil

# A signal handler is shutting us down (it exits with 128+signal): leave the
# exit to it instead of racing it with the "no exit status" path below.
sleep if Cleanup.stopping?

# Like ssh, hand rsync the remote exit code and the remote stderr text.
remote_rc = 0
result = begin
  read_remote_result(master, run_tok, RESULT_TIMEOUT)
rescue
  nil
end
sleep if Cleanup.stopping?
if result
  text, remote_rc = result
  STDERR.puts text unless text.empty?
else
  STDERR.puts "ssm-scp: warning: no exit status from the remote rsync (assuming success)"
end
Cleanup.run
master.close rescue nil
exit remote_rc
