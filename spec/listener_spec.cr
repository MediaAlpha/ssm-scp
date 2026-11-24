require "./spec_helper"
require "socket"

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

LTOK = "SSMRSHlistenerspec"

# Runs the listener with `command`, connects once, sends `input`, and returns
# {what came back through the socket, what the listener wrote on its stdout
# after the PORT= line}.
def run_listener(command : String, input : String = "") : {String, String}
  cmd = SsmScp::Remote.listener_command(false, command, LTOK)
  proc = Process.new("/bin/sh", ["-c", cmd], clear_env: false,
    input: Process::Redirect::Close, output: Process::Redirect::Pipe,
    error: Process::Redirect::Close)
  begin
    port = read_listener_port(proc.output) || raise "no PORT= line from listener"
    sock = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
    sock.read_timeout = 5.seconds
    sock.write(input.to_slice)
    sock.close_write
    echoed = IO::Memory.new
    IO.copy(sock, echoed)
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
    cmd = SsmScp::Remote.listener_command(false, "cat", LTOK)
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
      # accept(); a dummy connection lets it exec cat, which sees EOF and
      # exits.  After a normal run the connect is refused, which we ignore.
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
end

describe "python listener: SIGHUP and accept timeout" do
  python = Process.find_executable("python3")

  it "survives a SIGHUP sent before connecting and still serves" do
    pending!("python3 not found") unless python
    proc = Process.new(python.to_s, ["-c", PYTHON_LISTENER, LTOK, "cat"], clear_env: false,
      input: Process::Redirect::Close, output: Process::Redirect::Pipe,
      error: Process::Redirect::Close)
    begin
      port = read_listener_port(proc.output) || raise "no PORT= line from listener"
      proc.signal(Signal::HUP)
      sleep 0.3.seconds
      proc.exists?.should be_true

      sock = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
      sock.read_timeout = 5.seconds
      sock.write("after hup\n".to_slice)
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
    cmd = SsmScp::Remote.listener_command(false, "cat", LTOK, 1)
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
