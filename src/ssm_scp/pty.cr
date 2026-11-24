lib LibPTY
  fun posix_openpt(oflag : LibC::Int) : LibC::Int
  fun grantpt(fd : LibC::Int) : LibC::Int
  fun unlockpt(fd : LibC::Int) : LibC::Int
  fun ptsname(fd : LibC::Int) : LibC::Char*
end

# O_RDWR | O_NOCTTY
{% if flag?(:darwin) %}
  PTY_OPEN_FLAGS = 0x20002 # O_RDWR (0x2) | O_NOCTTY (0x20000), macOS
{% else %}
  PTY_OPEN_FLAGS = 0x102 # O_RDWR (0x2) | O_NOCTTY (0x100), Linux x86_64
{% end %}

module SsmScp
  # Opens a PTY pair with echo switched off on the slave side.
  # Raises SsmScp::Error if any step fails.
  def self.open_pty : {IO::FileDescriptor, IO::FileDescriptor}
    master_raw = LibPTY.posix_openpt(PTY_OPEN_FLAGS)
    raise Error.new("posix_openpt failed") if master_raw < 0
    raise Error.new("grantpt failed") if LibPTY.grantpt(master_raw) != 0
    raise Error.new("unlockpt failed") if LibPTY.unlockpt(master_raw) != 0
    name_ptr = LibPTY.ptsname(master_raw)
    raise Error.new("ptsname failed") if name_ptr.null?
    slave_raw = LibC.open(String.new(name_ptr), PTY_OPEN_FLAGS)
    raise Error.new("open slave PTY failed") if slave_raw < 0

    attrs = LibC::Termios.new
    raise Error.new("tcgetattr failed") if LibC.tcgetattr(slave_raw, pointerof(attrs)) != 0
    attrs.c_lflag = attrs.c_lflag & ~typeof(attrs.c_lflag).new(LibC::ECHO)
    raise Error.new("tcsetattr failed") if LibC.tcsetattr(slave_raw, LibC::TCSANOW, pointerof(attrs)) != 0

    master = IO::FileDescriptor.new(master_raw)
    master.sync = true
    slave = IO::FileDescriptor.new(slave_raw)
    # Neither end may leak into other children we start (e.g. the port-forward
    # `aws`, which would then hold the PTY open).  Process.new dup2s the slave
    # onto the child's stdio, which clears the flag on those copies only.
    master.close_on_exec = true
    slave.close_on_exec = true
    {master, slave}
  end

  module Sentinel
    # Looks for `<sentinel><digits>` in buf[from..] and returns the number, or
    # nil.  `from` may fall in the middle of a UTF-8 sequence, hence the scrub.
    def self.scan(buf : Bytes, sentinel : String, from : Int32 = 0) : Int32?
      start = from.clamp(0, buf.size)
      tail = String.new(buf[start..]).scrub
      pattern = /#{Regex.escape(sentinel)}(\d+)/
      (m = pattern.match(tail)) ? m[1].to_i : nil
    end

    # Where to resume scanning after `scanned` bytes were already searched:
    # a little earlier, so a sentinel split across two reads is still found.
    def self.resume_from(scanned : Int32, sentinel : String) : Int32
      {scanned - sentinel.bytesize - 8, 0}.max
    end

    # The frame the remote listener writes when rsync is done: `<token>B`,
    # rsync's stderr text, then `<token><rc>` and a newline (so a split read
    # cannot truncate a multi-digit rc).  Returns {stderr text, rc} or nil.
    # Input is raw PTY text; ANSI codes are stripped.
    def self.result(raw : String, token : String) : {String, Int32}?
      tok = Regex.escape(token)
      m = /#{tok}B\n(.*?)#{tok}(\d+)\n/m.match(strip_ansi(raw))
      return unless m
      rc = m[2].to_i? || return
      {m[1].rstrip, rc}
    end

    # Is there a complete `<token><digits>` line in buf[from..]?  Used to
    # decide cheaply (on the new bytes only) when to parse a frame.
    def self.line_end?(buf : Bytes, token : String, from : Int32 = 0) : Bool
      start = from.clamp(0, buf.size)
      /#{Regex.escape(token)}\d+\n/.matches?(strip_ansi(String.new(buf[start..])))
    end

    # The answer to Remote.check_command: {overall rc, [{code, path}]} once
    # `<token><rc>` has arrived, else nil.  Input is raw PTY text.
    def self.check(raw : String, token : String) : {Int32, Array({Int32, String})}?
      text = strip_ansi(raw)
      tok = Regex.escape(token)
      m = /#{tok}(\d+)\n/.match(text) || return
      failures = [] of {Int32, String}
      text[0, m.begin].scan(/(?m)^#{tok}F(\d) ([^\n]*)$/) do |found|
        failures << {found[1].to_i, found[2]}
      end
      {m[1].to_i, failures}
    end

    # Does the tail of the output (the last `window` bytes) end in a shell
    # prompt?  Only the tail is looked at, so the work does not grow with the
    # amount of output.
    def self.prompt?(buf : Bytes, window : Int32 = 1024) : Bool
      PROMPT_RE.matches?(strip_ansi(String.new(buf[{buf.size - window, 0}.max..])))
    end

    # `PORT=<digits>` followed by a newline (so a split read cannot yield a
    # truncated port).  Input is raw PTY text; ANSI codes are stripped.
    def self.port(raw : String) : Int32?
      (m = /PORT=(\d+)\n/.match(strip_ansi(raw))) ? m[1].to_i32 : nil
    end
  end
end

# ── PTY read helpers ──────────────────────────────────────────────────────────
# `master` is any IO::FileDescriptor (a PTY master in production, a pipe in specs).

def pty_read_chunk(master : IO::FileDescriptor, timeout : Float64) : Bytes
  master.read_timeout = timeout.seconds
  buf = Bytes.new(4096)
  n = master.read(buf)
  # 0 bytes from a blocking-with-timeout read means EOF (the slave side is
  # gone), not "no data yet" — that case raises IO::TimeoutError.
  raise SsmScp::Error.new("remote shell closed unexpectedly") if n == 0
  buf[0, n]
rescue IO::TimeoutError
  Bytes.empty
rescue IO::Error
  raise SsmScp::Error.new("remote shell closed unexpectedly")
end

def wait_for_prompt(master : IO::FileDescriptor, timeout : Float64) : {Bool, String}
  acc = IO::Memory.new
  deadline = Time.instant + timeout.seconds
  while Time.instant < deadline
    chunk = begin
      pty_read_chunk(master, 0.2)
    rescue ex : SsmScp::Error
      # The session closed.  Whatever it printed first (e.g. the aws error
      # text) is the useful part; only raise if there is nothing to show.
      raise ex if acc.empty?
      return {false, strip_ansi(acc.to_s).strip}
    end
    next if chunk.empty?
    acc.write(chunk)
    return {true, ""} if SsmScp::Sentinel.prompt?(acc.to_slice)
  end
  {false, strip_ansi(acc.to_s).strip}
end

# Reads until `<sentinel><digits>` shows up.  Returns {rc, everything read},
# or {-1, ...} on timeout.  Each read only rescans the new bytes (plus a small
# overlap), so the work stays linear.
def read_sentinel_buffer(master : IO::FileDescriptor, sentinel : String, timeout : Float64) : {Int32, IO::Memory}
  full = IO::Memory.new
  scanned = 0
  deadline = Time.instant + timeout.seconds
  while Time.instant < deadline
    chunk = pty_read_chunk(master, 0.1)
    next if chunk.empty?
    full.write(chunk)
    from = SsmScp::Sentinel.resume_from(scanned, sentinel)
    scanned = full.bytesize.to_i32
    if rc = SsmScp::Sentinel.scan(full.to_slice, sentinel, from)
      return {rc, full}
    end
  end
  {-1, full}
end

# Returns the digits after the sentinel, or -1 on timeout.
def read_until_sentinel(master : IO::FileDescriptor, sentinel : String, timeout : Float64) : Int32
  read_sentinel_buffer(master, sentinel, timeout)[0]
end

# The answer to Remote.check_command: {rc, [{code, path}]}; rc -1 on timeout.
def read_check_result(master : IO::FileDescriptor, token : String, timeout : Float64) : {Int32, Array({Int32, String})}
  rc, full = read_sentinel_buffer(master, token, timeout)
  return {-1, [] of {Int32, String}} if rc < 0
  SsmScp::Sentinel.check(full.to_s, token) || {rc, [] of {Int32, String}}
end

# Reads PTY output until PORT=\d+ appears, returns the port number.  Only
# the new bytes (plus an overlap) are searched on each read.
def read_remote_port(master : IO::FileDescriptor, timeout : Float64) : Int32?
  acc = IO::Memory.new
  scanned = 0
  deadline = Time.instant + timeout.seconds
  while Time.instant < deadline
    chunk = pty_read_chunk(master, 0.2)
    next if chunk.empty?
    acc.write(chunk)
    from = SsmScp::Sentinel.resume_from(scanned, "PORT=")
    scanned = acc.bytesize.to_i32
    if port = SsmScp::Sentinel.port(String.new(acc.to_slice[from..]))
      return port
    end
  end
  nil
end

# Reads the PTY until the listener's result frame for `token` arrives.
# Returns {rsync's stderr text, rc}, or nil on timeout or if the session
# closed first.  The frame is only parsed once its closing line is in; that is
# looked for in the new bytes alone.
def read_remote_result(master : IO::FileDescriptor, token : String, timeout : Float64) : {String, Int32}?
  acc = IO::Memory.new
  scanned = 0
  deadline = Time.instant + timeout.seconds
  while Time.instant < deadline
    chunk = begin
      pty_read_chunk(master, 0.2)
    rescue SsmScp::Error
      return SsmScp::Sentinel.result(acc.to_s, token)
    end
    next if chunk.empty?
    acc.write(chunk)
    from = SsmScp::Sentinel.resume_from(scanned, token)
    scanned = acc.bytesize.to_i32
    next unless SsmScp::Sentinel.line_end?(acc.to_slice, token, from)
    if res = SsmScp::Sentinel.result(acc.to_s, token)
      return res
    end
  end
  nil
end
