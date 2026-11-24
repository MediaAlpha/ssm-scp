require "./spec_helper"
require "socket"

# Why `bash --noediting`: with readline (the default for `bash -i`) the shell
# echoes typed input itself even when the tty has ECHO off, so a command such
# as `printf 'TOK0\n'` would appear in the output and could be mistaken for the
# sentinel.  --noediting leaves echo to the tty (off), like the real remote
# session after `stty -echo`.  A plain `/bin/sh -i` is bash-in-posix-mode on
# macOS and dash on Debian, so its behaviour differs per platform.
describe "phase 1 against a local shell on a real PTY" do
  it "runs the preflight and the listener through the real helpers" do
    bash = Process.find_executable("bash")
    pending!("bash not found") unless bash

    master, slave = SsmScp.open_pty
    shell = Process.new(bash.to_s, ["--norc", "--noprofile", "--noediting", "-i"],
      env: {"PS1" => "$ ", "TERM" => "dumb"},
      input: slave, output: slave, error: slave)
    slave.close
    ports = [] of Int32
    begin
      ok, out = wait_for_prompt(master, 5.0)
      ok.should be_true, "no prompt, got: #{out.inspect}"

      with_tmp_dir do |dir|
        write_script(dir / "rsync", "exit 0")
        master.print("export PATH=#{dir}:$PATH\n")
        tok = new_token
        master.print(SsmScp::Remote.preflight_command(tok))
        read_until_sentinel(master, tok, 5.0).should eq 0
      end

      master.print(SsmScp::Remote.listener_command(false, "cat"))
      port = read_remote_port(master, 5.0)
      port.should be_a(Int32)
      if port
        ports << port
      end
    ensure
      # Release python from accept() so it execs cat, then stop the shell.
      ports.each do |tcp_port|
        TCPSocket.new("127.0.0.1", tcp_port, connect_timeout: 1.second).close
      rescue
        nil
      end
      # Interactive bash ignores SIGTERM, so KILL.
      shell.signal(Signal::KILL) rescue nil
      shell.wait rescue nil
      master.close rescue nil
    end
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
end
