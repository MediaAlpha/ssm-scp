require "./spec_helper"
require "socket"

lib LibC
  fun getsid(pid : PidT) : PidT
end

# Reads from `io` until the buffer contains PORT=<digits>\n.
def read_listener_port(io : IO::FileDescriptor, timeout : Time::Span = 5.seconds) : Int32?
  io.read_timeout = timeout
  buf = IO::Memory.new
  chunk = Bytes.new(256)
  loop do
    n = io.read(chunk)
    break if n == 0
    buf.write(chunk[0, n])
    if port = SsmScp::Sentinel.port(buf.to_s)
      return port
    end
  end
  nil
rescue IO::TimeoutError
  nil
end

LTOK  = "SSMRSHlistenerspec"
LAUTH = "0123456789abcdef0123456789abcdef"

# Runs the listener with `command`, connects once, sends `send_auth` and then
# `input`, and returns {what came back through the socket, what the listener
# wrote on its stdout after the PORT= line}.  `chunks` splits the auth token
# over several writes; `env` is added to the listener's environment.
def run_listener(command : String, input : String = "", send_auth : String = LAUTH,
                 env : Hash(String, String) = {} of String => String,
                 chunks : Int32 = 1) : {String, String}
  cmd = SsmScp::Remote.listener_command(false, command, LTOK, LAUTH, 60, 2)
  proc = Process.new("/bin/sh", ["-c", cmd], env: env, clear_env: false,
    input: Process::Redirect::Close, output: Process::Redirect::Pipe,
    error: Process::Redirect::Close)
  begin
    port = read_listener_port(proc.output) || raise "no PORT= line from listener"
    sock = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
    sock.read_timeout = 5.seconds
    sock.tcp_nodelay = true
    if chunks > 1 && send_auth.size >= chunks
      step = send_auth.size // chunks
      send_auth.bytes.each_slice(step) do |part|
        sock.write(Bytes.new(part.to_unsafe, part.size))
        sleep 0.05.seconds
      end
    else
      sock.write(send_auth.to_slice)
    end
    sock.write(input.to_slice)
    sock.close_write
    echoed = IO::Memory.new
    begin
      IO.copy(sock, echoed)
    rescue IO::Error
      # a refused client may get a reset instead of a plain EOF
    end
    sock.close
    proc.output.read_timeout = 5.seconds
    {echoed.to_s, proc.output.gets_to_end}
  ensure
    proc.output.close rescue nil
    proc.wait rescue nil
  end
end

describe "python listener (Remote.listener_command)" do
  it "is a binary-clean, one-shot tunnel endpoint" do
    cmd = SsmScp::Remote.listener_command(false, "cat", LTOK, LAUTH)
    proc = Process.new("/bin/sh", ["-c", cmd], clear_env: false,
      input: Process::Redirect::Close, output: Process::Redirect::Pipe,
      error: Process::Redirect::Close)
    ports = [] of Int32
    begin
      port = read_listener_port(proc.output) || raise "no PORT= line from listener"
      ports << port

      payload = IO::Memory.new
      256.times { |i| payload.write_byte(i.to_u8) }
      payload << "\r\nline\r\n\x03\x03\r\n"
      256.times { |i| payload.write_byte((255 - i).to_u8) }
      expected = payload.to_slice.dup

      sock = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
      sock.read_timeout = 5.seconds
      sock.write(LAUTH.to_slice)
      sock.write(expected)
      sock.close_write
      echoed = IO::Memory.new
      IO.copy(sock, echoed)
      sock.close
      echoed.to_slice.should eq expected

      # One-shot: the listener socket is closed once the first connection is taken.
      expect_raises(Socket::ConnectError) do
        TCPSocket.new("127.0.0.1", port, connect_timeout: 2.seconds).close
      end
    ensure
      # If the example failed before connecting, python is still blocked in
      # accept(); a dummy connection lets it end (a wrong token is refused).
      # After a normal run the connect is refused, which we ignore.
      ports.each do |tcp_port|
        TCPSocket.new("127.0.0.1", tcp_port, connect_timeout: 1.second).close
      rescue
        nil
      end
      proc.output.close rescue nil
      proc.wait
    end
  end
end

describe "python listener: remote stderr and exit status" do
  python = Process.find_executable("python3")

  it "reports a clean run as rc 0 with no text, and the echo is byte-identical" do
    pending!("python3 not found") unless python
    echoed, frame = run_listener("cat", "hello\r\n\x00\xff\n")
    echoed.should eq "hello\r\n\x00\xff\n"
    SsmScp::Sentinel.result(frame, LTOK).should eq({"", 0})
  end

  it "frames the child's stderr text and exit code on stdout, keeping the socket clean" do
    pending!("python3 not found") unless python
    echoed, frame = run_listener("sh -c 'echo out; echo oops >&2; exit 23'")
    echoed.should eq "out\n"
    SsmScp::Sentinel.result(frame, LTOK).should eq({"oops", 23})
  end

  it "does not truncate a multi-line message or a multi-digit rc" do
    pending!("python3 not found") unless python
    _, frame = run_listener("sh -c 'echo one >&2; echo two >&2; exit 255'")
    SsmScp::Sentinel.result(frame, LTOK).should eq({"one\ntwo", 255})
  end

  it "reports a command that cannot start as rc 127 with a message (via env)" do
    pending!("python3 not found") unless python
    _, frame = run_listener("no-such-command-ssmscp")
    result = SsmScp::Sentinel.result(frame, LTOK)
    result.should_not be_nil
    text, rc = result.as({String, Int32})
    rc.should eq 127
    text.should contain "no-such-command-ssmscp"
  end

  it "reports a child killed by a signal as 128+signum" do
    pending!("python3 not found") unless python
    _, frame = run_listener("sh -c 'kill -9 $$'")
    SsmScp::Sentinel.result(frame, LTOK).should eq({"", 137})
  end

  it "writes the frame as raw bytes: non-ASCII stderr survives an ASCII locale" do
    pending!("python3 not found") unless python
    with_tmp_dir do |dir|
      write_script(dir / "err.sh", "printf 'caf\\303\\251 \\342\\202\\254 \\377\\n' >&2; exit 3")
      env = {"PYTHONIOENCODING" => "ascii", "LC_ALL" => "C", "LANG" => "C"}
      _, frame = run_listener((dir / "err.sh").to_s, env: env)
      result = SsmScp::Sentinel.result(frame, LTOK)
      result.should_not be_nil
      text, rc = result.as({String, Int32})
      rc.should eq 3
      text.should start_with "café €"
    end
  end
end

describe "python listener: auth token" do
  python = Process.find_executable("python3")

  it "runs the command when the token is right, even when it arrives in pieces" do
    pending!("python3 not found") unless python
    echoed, frame = run_listener("cat", "payload", chunks: 4)
    echoed.should eq "payload"
    SsmScp::Sentinel.result(frame, LTOK).should eq({"", 0})
  end

  it "does not run the command on a wrong token: rc 126 with a message" do
    pending!("python3 not found") unless python
    with_tmp_dir do |dir|
      marker = dir / "ran"
      write_script(dir / "cmd.sh", "touch #{marker}; cat")
      wrong = LAUTH.sub(/.\z/, "x")
      echoed, frame = run_listener((dir / "cmd.sh").to_s, "data", wrong)
      echoed.should eq ""
      result = SsmScp::Sentinel.result(frame, LTOK)
      result.should_not be_nil
      text, rc = result.as({String, Int32})
      rc.should eq 126
      text.should contain "auth failed"
      sleep 0.2.seconds
      File.exists?(marker).should be_false
    end
  end

  it "rejects a token that is too short, empty, or only a prefix" do
    pending!("python3 not found") unless python
    with_tmp_dir do |dir|
      write_script(dir / "cmd.sh", "touch #{dir}/ran; cat")
      {"", LAUTH[0, 8], LAUTH[0, 31]}.each do |short|
        _, frame = run_listener((dir / "cmd.sh").to_s, "", short)
        SsmScp::Sentinel.result(frame, LTOK).try(&.[1]).should eq 126
      end
      File.exists?(dir / "ran").should be_false
    end
  end

  it "gives up on a client that connects and sends nothing (the auth read has a timeout)" do
    pending!("python3 not found") unless python
    cmd = SsmScp::Remote.listener_command(false, "cat", LTOK, LAUTH, 60, 1)
    proc = Process.new("/bin/sh", ["-c", cmd], clear_env: false,
      input: Process::Redirect::Close, output: Process::Redirect::Pipe,
      error: Process::Redirect::Close)
    begin
      port = read_listener_port(proc.output) || raise "no PORT= line from listener"
      sock = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
      started = Time.instant
      proc.output.read_timeout = 6.seconds
      frame = proc.output.gets_to_end
      (Time.instant - started).should be < 5.seconds
      SsmScp::Sentinel.result(frame, LTOK).try(&.[1]).should eq 126
      sock.close
    ensure
      proc.output.close rescue nil
      proc.wait rescue nil
    end
  end

  it "fails closed when the environment carries no token at all" do
    pending!("python3 not found") unless python
    proc = Process.new(python.to_s, ["-c", SsmScp::Remote.python_listener, LTOK, "cat"],
      env: {AUTH_ENV => nil}, clear_env: false,
      input: Process::Redirect::Close, output: Process::Redirect::Pipe,
      error: Process::Redirect::Close)
    begin
      port = read_listener_port(proc.output) || raise "no PORT= line from listener"
      sock = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
      sock.close_write
      proc.output.read_timeout = 6.seconds
      SsmScp::Sentinel.result(proc.output.gets_to_end, LTOK).try(&.[1]).should eq 126
      sock.close
    ensure
      proc.output.close rescue nil
      proc.wait rescue nil
    end
  end
end

describe "python listener: SIGHUP, own session and accept timeout" do
  python = Process.find_executable("python3")

  # Real property: the command runs in a session of its own, so the hangup
  # that follows a closing PTY session (SIGHUP to the shell's foreground
  # process group) cannot reach it, and a SIGHUP sent to the listener itself
  # changes nothing for the transfer.
  it "runs the command in its own session and survives SIGHUP to the listener" do
    pending!("python3 not found") unless python
    with_tmp_dir do |dir|
      File.write(dir / "child.py", <<-'PY')
        import os, sys
        sys.stdout.write('%d %d %d\n' % (os.getpid(), os.getsid(0), os.getpgrp()))
        sys.stdout.flush()
        sys.stdout.write(sys.stdin.read().upper())
        PY
      proc = Process.new(python.to_s, ["-c", SsmScp::Remote.python_listener, LTOK, python.to_s, (dir / "child.py").to_s],
        env: {AUTH_ENV => LAUTH}, clear_env: false,
        input: Process::Redirect::Close, output: Process::Redirect::Pipe,
        error: Process::Redirect::Close)
      begin
        port = read_listener_port(proc.output) || raise "no PORT= line from listener"
        sock = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
        sock.read_timeout = 5.seconds
        sock.write(LAUTH.to_slice)
        line = sock.gets || raise "no ids from the command"
        child_pid, child_sid, child_pgrp = line.split.map(&.to_i)
        child_sid.should eq child_pid
        child_pgrp.should eq child_pid
        child_sid.should_not eq LibC.getsid(proc.pid)
        child_pgrp.should_not eq LibC.getpgid(proc.pid)

        proc.signal(Signal::HUP)
        sleep 0.3.seconds
        proc.exists?.should be_true
        sock.write("after hup\n".to_slice)
        sock.close_write
        rest = IO::Memory.new
        IO.copy(sock, rest)
        sock.close
        rest.to_s.should eq "AFTER HUP\n"
      ensure
        proc.terminate rescue nil
        proc.output.close rescue nil
        proc.wait rescue nil
      end
    end
  end

  it "survives a SIGHUP sent before connecting and still serves" do
    pending!("python3 not found") unless python
    proc = Process.new(python.to_s, ["-c", SsmScp::Remote.python_listener, LTOK, "cat"],
      env: {AUTH_ENV => LAUTH}, clear_env: false,
      input: Process::Redirect::Close, output: Process::Redirect::Pipe,
      error: Process::Redirect::Close)
    begin
      port = read_listener_port(proc.output) || raise "no PORT= line from listener"
      proc.signal(Signal::HUP)
      sleep 0.3.seconds
      proc.exists?.should be_true

      sock = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
      sock.read_timeout = 5.seconds
      sock.write((LAUTH + "after hup\n").to_slice)
      sock.close_write
      echoed = IO::Memory.new
      IO.copy(sock, echoed)
      sock.close
      echoed.to_s.should eq "after hup\n"
    ensure
      proc.terminate rescue nil
      proc.output.close rescue nil
      proc.wait rescue nil
    end
  end

  it "exits by itself when nobody connects within the accept timeout" do
    pending!("python3 not found") unless python
    cmd = SsmScp::Remote.listener_command(false, "cat", LTOK, LAUTH, 1)
    proc = Process.new("/bin/sh", ["-c", cmd], clear_env: false,
      input: Process::Redirect::Close, output: Process::Redirect::Pipe,
      error: Process::Redirect::Close)
    begin
      port = read_listener_port(proc.output) || raise "no PORT= line from listener"
      started = Time.instant
      # The listener holds the pipe's write end; EOF means it has exited.
      proc.output.read_timeout = 6.seconds
      rest = proc.output.gets_to_end
      rest.should eq ""
      (Time.instant - started).should be < 5.seconds
      expect_raises(Socket::ConnectError) do
        TCPSocket.new("127.0.0.1", port, connect_timeout: 2.seconds).close
      end
    ensure
      proc.output.close rescue nil
      proc.wait
    end
  end
end
