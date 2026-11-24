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

describe "python listener (Remote.listener_command)" do
  it "is a binary-clean, one-shot tunnel endpoint" do
    cmd = SsmScp::Remote.listener_command(false, "cat")
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

describe "python listener: SIGHUP and accept timeout" do
  python = Process.find_executable("python3")

  it "survives a SIGHUP sent before connecting and still serves" do
    pending!("python3 not found") unless python
    proc = Process.new(python.to_s, ["-c", PYTHON_LISTENER, "cat"], clear_env: false,
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
    cmd = SsmScp::Remote.listener_command(false, "cat", 1)
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
