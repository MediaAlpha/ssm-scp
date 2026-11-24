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
      cmd = SsmScp::Remote.listener_command(false, "rsync --server -r . /a\\ b", "TOK", "AUTH")
      cmd.should end_with " TOK rsync --server -r . /a\\ b 2>/dev/null &\n"
      cmd.should_not contain "'sudo'"
    end
  end
end

describe SsmScp::ServerArgs do
  describe ".unescape" do
    it "undoes rsync's backslash escaping for display" do
      SsmScp::ServerArgs.unescape("/tmp/my\\ dir/\\*.log").should eq "/tmp/my dir/*.log"
      SsmScp::ServerArgs.unescape("a\\\\b").should eq "a\\b"
      SsmScp::ServerArgs.unescape("plain").should eq "plain"
    end
  end
end

describe SsmScp::Remote do
  describe ".check_command" do
    it "tests existence and readability of each (unquoted) path without sudo" do
      cmd = SsmScp::Remote.check_command("/a /b*", false, "TOK")
      cmd.should start_with "rc=0; for f in /a /b*; do "
      cmd.should contain %([ -e "$f" ])
      cmd.should contain %([ -r "$f" ])
      cmd.should contain %(ls -d -- "$f")
      cmd.should end_with %(printf '%s%s\\n' 'TOK' "$rc"\n)
      cmd.should_not contain "sudo"
    end

    it "probes each path with sudo -n ls -d -- under --sudo" do
      cmd = SsmScp::Remote.check_command("/a /b", true, "TOK")
      cmd.should start_with "rc=0; for f in /a /b; do o=$(sudo -n env LC_ALL=C ls -d -- \"$f\" 2>&1); "
      cmd.should contain "*sudo:*) c=3"
      cmd.should end_with %(printf '%s%s\\n' 'TOK' "$rc"\n)
    end

    it "always lists in the C locale with -d -- so the 'ermission' match is locale independent" do
      SsmScp::Remote.check_command("/a", false, "TOK").should contain %(LC_ALL=C ls -d -- "$f")
      SsmScp::Remote.check_command("/a", true, "TOK").should contain %(env LC_ALL=C ls -d -- "$f")
    end

    it "never puts token+digit in the command (echo cannot fake an answer), with or without sudo" do
      {false, true}.each do |sudo|
        SsmScp::Remote.check_command("/a /b", sudo, "TOK").should_not match(/TOK\d/)
      end
    end
  end

  describe ".check_failure" do
    it "rc 2 = not found, never suggests --sudo" do
      SsmScp::Remote.check_failure(2, ["/x", "/y"]).should eq "cannot access remote path: /x, /y (file does not exist on remote)"
      SsmScp::Remote.check_failure(2, ["/x"], true).should_not contain "sudo"
    end

    it "rc 1 = permission denied with chmod hints for the file and its parent directory" do
      msg = SsmScp::Remote.check_failure(1, ["/srv/app/secret"])
      msg.should contain "permission denied — try --sudo"
      msg.should contain "chmod o+r '/srv/app/secret'"
      msg.should contain "chmod o+x '/srv/app'"
      msg.should contain "passwordless sudo"
    end

    it "rc 1 with sudo already used does not suggest --sudo" do
      msg = SsmScp::Remote.check_failure(1, ["/srv/app/secret"], true)
      msg.should contain "permission denied, even with sudo"
      msg.should_not contain "try --sudo"
      msg.should_not contain "chmod"
    end

    it "rc 3 = sudo needs a password" do
      msg = SsmScp::Remote.check_failure(3, ["/root/x"], true)
      msg.should contain "sudo needs a password"
      msg.should contain "passwordless sudo"
      msg.should_not contain "permission denied"
    end

    it "rc -1 = timeout, not 'does not exist'" do
      msg = SsmScp::Remote.check_failure(-1, ["/x"])
      msg.should contain "timed out"
      msg.should_not contain "does not exist"
    end

    it "names only the failing paths the remote reported" do
      msg = SsmScp::Remote.check_failure(2, ["/a", "/b", "/c"], false, ["/b"])
      msg.should start_with "cannot access remote path: /b "
      msg.should_not contain "/a"
    end

    it "shows rsync's escaped paths unescaped, and builds the chmod hint from them" do
      msg = SsmScp::Remote.check_failure(1, ["/srv/my\\ app/it\\'s"])
      msg.should start_with "cannot access remote path: /srv/my app/it's "
      msg.should contain "chmod o+r '/srv/my app/it'\\''s'"
      msg.should contain "chmod o+x '/srv/my app'"
      msg.should_not contain "my\\ app"
    end
  end

  describe ".wrap" do
    it "sends a short command as one eval line with the base64 payload" do
      line = SsmScp::Remote.wrap("echo hi")
      line.should eq %(eval "$(printf %s #{Base64.strict_encode("echo hi")} | base64 -d)"\n)
    end

    it "splits a long payload into short lines that rebuild it" do
      cmd = "echo " + ("é\t'x" * 300)
      text = SsmScp::Remote.wrap(cmd, 100)
      lines = text.lines
      lines.size.should be > 3
      lines.each(&.size.should(be < 160))
      lines.last.should eq %(eval "$(printf %s "$ssm_b" | base64 -d)"; unset ssm_b)
      lines.first.should start_with "ssm_b="
      lines[1].should start_with "ssm_b=${ssm_b}"
    end

    it "only carries base64 characters in the payload lines" do
      text = SsmScp::Remote.wrap("a\tb\x01\x7fé\n'\"$`\\!", 8)
      text.lines.size.should be > 2
      text.lines[0..-2].each { |line| line.chomp.should match(/\Assm_b=(\$\{ssm_b\})?[A-Za-z0-9+\/=]+\z/) }
      one = SsmScp::Remote.wrap("a\tb\x01\x7fé\n'\"$`\\!").chomp
      one.should match(/\Aeval "\$\(printf %s [A-Za-z0-9+\/=]+ \| base64 -d\)"\z/)
    end
  end

  describe ".send" do
    it "types the lines one at a time, pausing between them, and loses nothing" do
      reader, writer = IO.pipe
      started = Time.instant
      spawn do
        SsmScp::Remote.send(writer, "one\ntwo\nthree\n", 0.1.seconds)
        writer.close
      end
      first = reader.gets(chomp: false)
      first.should eq "one\n"
      (Time.instant - started).should be < 0.09.seconds
      reader.gets_to_end.should eq "two\nthree\n"
      (Time.instant - started).should be >= 0.19.seconds
      reader.close
    end

    it "sends a single line at once" do
      reader, writer = IO.pipe
      SsmScp::Remote.send(writer, "only\n", 5.seconds)
      writer.close
      reader.gets_to_end.should eq "only\n"
      reader.close
    end
  end

  describe ".listener_command" do
    it "wraps the python listener in double quotes, passes the auth in the environment and backgrounds it" do
      cmd = SsmScp::Remote.listener_command(false, "rsync --server .", "TOK", "AUTH")
      cmd.should start_with %(SSMRSH_AUTH=AUTH python3 -c "#{SsmScp::Remote.python_listener}" TOK rsync --server .)
      cmd.should end_with " 2>/dev/null &\n"
    end

    it "keeps the auth token out of argv" do
      cmd = SsmScp::Remote.listener_command(false, "rsync --server .", "TOK", "s3cr3tval")
      cmd.index!("s3cr3tval").should be < cmd.index!("python3")
      cmd.scan("s3cr3tval").size.should eq 1
    end

    it "prefixes sudo" do
      SsmScp::Remote.listener_command(true, "rsync --server .", "TOK", "A").should contain %(" TOK 'sudo' '-n' rsync --server .)
    end

    it "the python listener has no double quote or shell-special characters" do
      {SsmScp::Remote.python_listener, SsmScp::Remote.python_listener(2.5)}.each do |script|
        script.should_not contain "\""
        script.should_not contain "$"
        script.should_not contain "`"
        script.should_not contain "\\"
        script.should_not contain "!"
      end
    end

    it "ignores SIGHUP before binding, times out the accept and leads the child's own session" do
      script = SsmScp::Remote.python_listener
      script.index!("signal.SIGHUP").should be < script.index!("bind")
      script.should contain "s.settimeout(#{LISTENER_ACCEPT_TIMEOUT})"
      script.should contain "c.settimeout(None)"
      script.should contain "start_new_session=True"
      LISTENER_ACCEPT_TIMEOUT.should eq 60
    end

    it "checks the auth token with hmac.compare_digest before running anything" do
      script = SsmScp::Remote.python_listener
      script.index!("hmac.compare_digest").should be < script.index!("subprocess.Popen")
      script.should contain "os.environ.pop('#{AUTH_ENV}'"
      script.scan("settimeout(").size.should eq 3 # accept, auth read, back to blocking
    end

    it "writes its frame as raw bytes" do
      script = SsmScp::Remote.python_listener
      script.should contain "sys.stdout.buffer"
      script.should_not contain "decode("
    end

    it "the accept timeout is injectable" do
      cmd = SsmScp::Remote.listener_command(false, "cat", "TOK", "A", 3)
      cmd.should contain "s.settimeout(3)"
      cmd.should_not contain "ACCEPT_TIMEOUT"
    end
  end

  describe ".preflight_command" do
    it "sets up the shell, goes home, checks rsync, python3 and base64, and prints token+rc via printf" do
      cmd = SsmScp::Remote.preflight_command("TOK")
      cmd.should contain "export PS1=''; command set +o history 2>/dev/null; "
      cmd.should contain "cd 2>/dev/null; "
      cmd.should contain "command -v rsync"
      cmd.should contain "command -v python3"
      cmd.should contain "command -v base64"
      cmd.should contain %(printf '%s%s\\n' 'TOK' "$rc")
      cmd.should end_with "\n"
    end

    it "is plain ASCII on one line (it cannot be base64-wrapped)" do
      cmd = SsmScp::Remote.preflight_command("TOK")
      cmd.chomp.should_not contain "\n"
      cmd.ascii_only?.should be_true
      cmd.bytesize.should be < 800
    end

    it "makes every setup step non-fatal" do
      cmd = SsmScp::Remote.preflight_command("TOK")
      cmd.should contain "stty -echo 2>/dev/null"
      cmd.should_not contain "; set +o history" # only `command set`, whose error cannot end a POSIX shell
      cmd.should contain "bind 'set enable-bracketed-paste off' 2>/dev/null"
    end

    it "the echoed command never contains token+digit (echo cannot fake success)" do
      SsmScp::Remote.preflight_command("TOK").should_not match(/TOK\d/)
    end
  end
end
