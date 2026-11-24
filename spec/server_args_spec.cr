require "./spec_helper"

private def sargs(*words : String)
  SsmScp::ServerArgs.new(words.to_a)
end

describe SsmScp::ServerArgs do
  describe "download vs upload pre-check" do
    it "download (--sender): pre-checks every path after the dot" do
      a = sargs("rsync", "--server", "--sender", "-vlogDtpre.iLsfxCIvu", ".", "/var/log/a.log", "/etc/hosts")
      a.download?.should be_true
      a.src_paths.should eq ["/var/log/a.log", "/etc/hosts"]
    end

    it "upload (no --sender): no pre-check, the path is a destination" do
      a = sargs("rsync", "--server", "-vlogDtpre.iLsfxCIvu", ".", "/new/dir/")
      a.download?.should be_false
      a.src_paths.should be_empty
    end

    it "no dot means nothing to check even with --sender" do
      a = sargs("rsync", "--server", "--sender", "-v")
      a.dot_index.should be_nil
      a.download?.should be_false
      a.src_paths.should be_empty
    end

    it "download of the remote home (path is just the dot itself)" do
      a = sargs("rsync", "--server", "--sender", "-r", ".", ".")
      a.dot_index.should eq 4
      a.src_paths.should eq ["."]
    end

    it "the first dot is the separator" do
      a = sargs("rsync", "--server", "--sender", ".", "./x", ".")
      a.src_paths.should eq ["./x", "."]
    end

    it "a dot with nothing after it yields no paths" do
      sargs("rsync", "--server", "--sender", ".").src_paths.should be_empty
    end

    it "sudo upload with --sender-less args also skips the check" do
      sargs("sudo", "rsync", "--server", "-r", ".", "/root/x").src_paths.should be_empty
    end
  end

  describe "rsync-escaped args are passed through unquoted" do
    it "keeps backslash escapes (\\* and \\ ) byte for byte" do
      a = sargs("rsync", "--server", "--sender", "-r", ".", "/tmp/my\\ dir/\\*.log")
      a.escaped.should eq "rsync --server --sender -r . /tmp/my\\ dir/\\*.log"
      a.src_paths.should eq ["/tmp/my\\ dir/\\*.log"]
    end

    it "keeps --chown/--usermap style values with escaped stars" do
      a = sargs("rsync", "--server", "-r", "--usermap=\\*:www", "--groupmap=\\*:www", ".", "/srv/")
      a.escaped.should contain "--usermap=\\*:www"
      a.escaped.should contain "--groupmap=\\*:www"
      a.escaped.should_not contain "'"
    end

    it "the unquoted words are re-parsed correctly by a POSIX shell" do
      a = sargs("printf", "%s,", "a\\ b", "\\*", "c")
      buf = IO::Memory.new
      Dir.cd(Dir.tempdir) do
        Process.run("/bin/sh", ["-c", a.escaped], output: buf)
      end
      buf.to_s.should eq "a b,*,c,"
    end

    it "does not add quoting to the listener command either" do
      cmd = SsmScp::Remote.listener_command(false, "rsync --server -r . /a\\ b")
      cmd.should end_with " rsync --server -r . /a\\ b 2>/dev/null &\n"
      cmd.should_not contain "'sudo'"
    end
  end
end

describe SsmScp::Remote do
  describe ".check_command" do
    it "uses plain ls without sudo and reports rc 0/1/2" do
      cmd = SsmScp::Remote.check_command("/a /b", false, "TOK")
      cmd.should start_with "if LC_ALL=C ls /a /b >/dev/null 2>&1; then printf 'TOK0\\n'; "
      cmd.should contain "elif LC_ALL=C ls /a /b 2>&1 | grep -qE 'ermission|sudo:'; then printf 'TOK1\\n'; "
      cmd.should end_with "else printf 'TOK2\\n'; fi\n"
      cmd.should_not contain "sudo -n"
    end

    it "uses sudo -n (fail fast, no password prompt) with --sudo in both probes, in the C locale" do
      cmd = SsmScp::Remote.check_command("/a", true, "TOK")
      cmd.should contain "if sudo -n env LC_ALL=C ls /a >/dev/null"
      cmd.should contain "elif sudo -n env LC_ALL=C ls /a 2>&1"
    end

    it "always lists in the C locale so the 'ermission' match is locale independent" do
      SsmScp::Remote.check_command("/a", false, "TOK").scan("LC_ALL=C ls").size.should eq 2
    end
  end

  describe ".check_failure" do
    it "rc 2 = not found" do
      SsmScp::Remote.check_failure(2, ["/x", "/y"]).should eq "cannot access remote path: /x, /y (file does not exist on remote)"
    end

    it "rc 1 = permission denied with a chmod hint on the parent directory" do
      msg = SsmScp::Remote.check_failure(1, ["/srv/app/secret"])
      msg.should contain "permission denied — try --sudo"
      msg.should contain "chmod o+x '/srv/app'"
      msg.should contain "passwordless sudo"
    end

    it "rc -1 = timeout, not 'does not exist'" do
      msg = SsmScp::Remote.check_failure(-1, ["/x"])
      msg.should contain "timed out"
      msg.should_not contain "does not exist"
    end
  end

  describe ".listener_command" do
    it "wraps the python listener in double quotes and backgrounds it" do
      cmd = SsmScp::Remote.listener_command(false, "rsync --server .")
      cmd.should start_with %(python3 -c "#{PYTHON_LISTENER}" rsync --server .)
      cmd.should end_with " 2>/dev/null &\n"
    end

    it "prefixes sudo" do
      SsmScp::Remote.listener_command(true, "rsync --server .").should contain %(" 'sudo' '-n' rsync --server .)
    end

    it "the python listener has no double quote or shell-special characters" do
      {PYTHON_LISTENER, SsmScp::Remote.python_listener(2.5)}.each do |script|
        script.should_not contain "\""
        script.should_not contain "$"
        script.should_not contain "`"
      end
    end

    it "ignores SIGHUP before binding and times out the accept" do
      PYTHON_LISTENER.index!("signal.SIGHUP").should be < PYTHON_LISTENER.index!("bind")
      PYTHON_LISTENER.should contain "s.settimeout(#{LISTENER_ACCEPT_TIMEOUT});"
      PYTHON_LISTENER.should contain "c.settimeout(None);"
      LISTENER_ACCEPT_TIMEOUT.should eq 60
    end

    it "the accept timeout is injectable" do
      cmd = SsmScp::Remote.listener_command(false, "cat", 3)
      cmd.should contain "s.settimeout(3);"
      cmd.should_not contain "ACCEPT_TIMEOUT"
    end
  end

  describe ".preflight_command" do
    it "sets up the shell, checks rsync and python3, and prints token+rc via printf" do
      cmd = SsmScp::Remote.preflight_command("TOK")
      cmd.should contain "stty -echo; export PS1=''; set +o history; "
      cmd.should contain "command -v rsync"
      cmd.should contain "command -v python3"
      cmd.should contain %(printf '%s%s\\n' 'TOK' "$rc")
      cmd.should end_with "\n"
    end

    it "the echoed command never contains token+digit (echo cannot fake success)" do
      SsmScp::Remote.preflight_command("TOK").should_not match(/TOK\d/)
    end

    it "does not run the old zstd probe" do
      SsmScp::Remote.preflight_command("TOK").should_not contain "version"
      SsmScp::Remote.responds_to?(:zstd_probe_command).should be_false
    end
  end
end
