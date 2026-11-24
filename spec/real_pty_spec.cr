require "./spec_helper"
require "socket"

# Starts `shell` on a real PTY, as the remote SSM shell would be.  Returns the
# PTY master and the process.  Echo is handled as on the real remote: the tty
# has ECHO off, and a shell with readline (the default for `bash -i`) echoes
# typed input itself anyway, which is why every snippet prints its rc via
# printf from separate words (the echo cannot contain token+digit).
private def start_shell(shell : String, args : Array(String), env : Hash(String, String), chdir : String)
  master, slave = SsmScp.open_pty
  proc = Process.new(shell, args, env: {"PS1" => "$ ", "TERM" => "dumb"}.merge(env), chdir: chdir,
    input: slave, output: slave, error: slave)
  slave.close
  {master, proc}
end

# The whole of phase 1 against a local shell on a PTY, through the real helpers:
# preflight, check, byte-safe command transport and the authenticated listener.
private def phase1_roundtrip(shell : String, args : Array(String)) : Nil
  python = Process.find_executable("python3")
  pending!("python3 not found") unless python
  # The shell starts in "/" with HOME set to dir, like an SSM shell that does
  # not start in the home directory.
  dir = Path[File.join(Dir.tempdir, "ssm-scp-spec-#{Random::Secure.hex(6)}")]
  Dir.mkdir_p(dir)
  master, proc = start_shell(shell, args, {"HOME" => dir.to_s}, "/")
  ports = [] of Int32
  begin
    ok, shown = wait_for_prompt(master, 5.0)
    ok.should be_true, "no prompt, got: #{shown.inspect}"

    begin
      write_script(dir / "rsync", "exit 0")
      master.print("export PATH=#{dir}:$PATH\n")
      tok = new_token
      master.print(SsmScp::Remote.preflight_command(tok))
      read_until_sentinel(master, tok, 5.0).should eq 0

      # `cd` in the preflight: the shell is in $HOME afterwards.
      File.write(dir / "in-cwd.txt", "x")
      tok_cd = new_token
      SsmScp::Remote.send(master, SsmScp::Remote.wrap(%([ -e in-cwd.txt ]; printf '%s%s\\n' '#{tok_cd}' "$?")))
      read_until_sentinel(master, tok_cd, 5.0).should eq 0

      # check_command: ok, missing (with the path named).
      File.write(dir / "a b", "x")
      tok_chk = new_token
      paths = "#{shell_escape((dir / "a b").to_s)} #{shell_escape((dir / "nope").to_s)}"
      SsmScp::Remote.send(master, SsmScp::Remote.wrap(SsmScp::Remote.check_command(paths, false, tok_chk)))
      rc, failures = read_check_result(master, tok_chk, 5.0)
      rc.should eq 2
      failures.should eq [{2, (dir / "nope").to_s}]

      # Awkward bytes survive the transport: TAB, é, quotes, control bytes.
      awkward = "a\tb é 'q' \"d\" $x `y` \\z \x01\x02\x1b[A end"
      out_file = dir / "awkward.bin"
      tok_w = new_token
      SsmScp::Remote.send(master, SsmScp::Remote.wrap(
        "printf %s #{shell_escape(awkward)} > #{shell_escape(out_file.to_s)}; printf '%s%s\\n' '#{tok_w}' 0"))
      read_until_sentinel(master, tok_w, 5.0).should eq 0
      File.read(out_file).should eq awkward

      # The authenticated listener: auth first, then the data is echoed by `cat`.
      run_tok = new_token
      auth = Random::Secure.hex(16)
      SsmScp::Remote.send(master, SsmScp::Remote.wrap(SsmScp::Remote.listener_command(false, "cat", run_tok, auth)))
      port = read_remote_port(master, 5.0)
      port.should be_a(Int32)
      if port
        ports << port
        sock = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
        sock.read_timeout = 5.seconds
        sock.write((auth + "hello\r\n\x00\xff").to_slice)
        sock.close_write
        echoed = IO::Memory.new
        IO.copy(sock, echoed)
        sock.close
        echoed.to_slice.should eq "hello\r\n\x00\xff".to_slice
        read_remote_result(master, run_tok, 5.0).should eq({"", 0})
      end
    ensure
      FileUtils.rm_rf(dir.to_s)
    end
  ensure
    # Release python from accept() (a wrong token ends it), then stop the shell.
    ports.each do |tcp_port|
      TCPSocket.new("127.0.0.1", tcp_port, connect_timeout: 1.second).close
    rescue
      nil
    end
    # Interactive shells ignore SIGTERM, so KILL.
    proc.signal(Signal::KILL) rescue nil
    proc.wait rescue nil
    master.close rescue nil
  end
end

describe "phase 1 against a local shell on a real PTY" do
  bash = Process.find_executable("bash")
  dash = File.exists?("/bin/dash") ? "/bin/dash" : Process.find_executable("dash")

  it "works with bash --noediting" do
    pending!("bash not found") unless bash
    phase1_roundtrip(bash.to_s, ["--norc", "--noprofile", "--noediting", "-i"])
  end

  # The real remote shell has readline: a typed tab would complete, and it
  # echoes by itself.  The base64 transport has to cope.
  it "works with bash and readline (as the SSM shell has)" do
    pending!("bash not found") unless bash
    phase1_roundtrip(bash.to_s, ["--norc", "--noprofile", "-i"])
  end

  it "works with an interactive dash (setup steps are non-fatal there)" do
    pending!("dash not found") unless dash
    phase1_roundtrip(dash.to_s, ["-i"])
  end
end

describe "PTY_OPEN_FLAGS" do
  # O_RDWR | O_NOCTTY.  Verified with python os.O_NOCTTY on macOS (0x20000)
  # and on x86_64 Linux (0x100).
  it "equals O_RDWR|O_NOCTTY for the platform" do
    {% if flag?(:darwin) %}
      PTY_OPEN_FLAGS.should eq 0x20002
    {% elsif flag?(:linux) %}
      PTY_OPEN_FLAGS.should eq 0x102
    {% else %}
      pending!("unknown platform")
    {% end %}
  end
end

describe "SsmScp.open_pty" do
  it "returns a master/slave pair with echo off on the slave" do
    master, slave = SsmScp.open_pty
    begin
      attrs = LibC::Termios.new
      LibC.tcgetattr(slave.fd, pointerof(attrs)).should eq 0
      (attrs.c_lflag & typeof(attrs.c_lflag).new(LibC::ECHO)).should eq 0
      slave.print "hi\n"
      slave.flush
      pty_read_chunk(master, 2.0).should_not be_empty
    ensure
      slave.close rescue nil
      master.close rescue nil
    end
  end

  it "sets close-on-exec on both ends, so no later child inherits them" do
    master, slave = SsmScp.open_pty
    begin
      master.close_on_exec?.should be_true
      slave.close_on_exec?.should be_true
      {master.fd, slave.fd}.each do |descriptor|
        buf = IO::Memory.new
        Process.run("/bin/sh", ["-c", "[ -e /dev/fd/#{descriptor} ] && echo open || echo closed"], output: buf)
        buf.to_s.strip.should eq "closed"
      end
    ensure
      slave.close rescue nil
      master.close rescue nil
    end
  end

  it "still gives a child the slave as stdin, stdout and stderr" do
    master, slave = SsmScp.open_pty
    begin
      child = Process.new("/bin/sh", ["-c", "[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo ttyok"],
        input: slave, output: slave, error: slave)
      slave.close
      acc = IO::Memory.new
      10.times do
        acc.write(pty_read_chunk(master, 0.3)) rescue break
        break if acc.to_s.includes?("ttyok")
      end
      acc.to_s.should contain "ttyok"
      child.wait
    ensure
      slave.close rescue nil
      master.close rescue nil
    end
  end
end
