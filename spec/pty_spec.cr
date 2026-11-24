require "./spec_helper"

# The PTY helpers only need an IO::FileDescriptor, so a plain pipe stands in
# for the PTY master: no processes, no network.

describe SsmScp::Sentinel do
  describe ".scan" do
    it "extracts the exit code" do
      SsmScp::Sentinel.scan("junk\r\nTOK0\r\n".to_slice, "TOK").should eq 0
      SsmScp::Sentinel.scan("TOK2\n".to_slice, "TOK").should eq 2
      SsmScp::Sentinel.scan("TOK17".to_slice, "TOK").should eq 17
    end

    it "returns nil without the sentinel or without a digit" do
      SsmScp::Sentinel.scan("nothing here".to_slice, "TOK").should be_nil
      SsmScp::Sentinel.scan("TOK".to_slice, "TOK").should be_nil
      SsmScp::Sentinel.scan("TOKx\n".to_slice, "TOK").should be_nil
      SsmScp::Sentinel.scan(Bytes.empty, "TOK").should be_nil
    end

    it "ignores a different token" do
      SsmScp::Sentinel.scan("OTHER0\n".to_slice, "TOK").should be_nil
    end

    it "finds a sentinel followed by lots of later output" do
      buf = "TOK0\n" + "[1] 12345 job notice and more text" + ("x" * 5000)
      SsmScp::Sentinel.scan(buf.to_slice, "TOK").should eq 0
    end

    it "ignores output before the `from` offset" do
      old = "TOK0\n" + ("x" * 200)
      SsmScp::Sentinel.scan(old.to_slice, "TOK", 5).should be_nil
      SsmScp::Sentinel.scan((old + "TOK1\n").to_slice, "TOK", 5).should eq 1
    end

    it "clamps `from` to the buffer" do
      SsmScp::Sentinel.scan("TOK0".to_slice, "TOK", 100).should be_nil
      SsmScp::Sentinel.scan("TOK0".to_slice, "TOK", -5).should eq 0
    end

    it "resume_from backs up by the sentinel length plus a margin, never below 0" do
      SsmScp::Sentinel.resume_from(100, "TOK").should eq 89
      SsmScp::Sentinel.resume_from(5, "TOK").should eq 0
      SsmScp::Sentinel.resume_from(0, "TOK").should eq 0
    end

    it "finds a sentinel that straddles the resume point" do
      buf = ("x" * 50) + "TOK" + "12"
      from = SsmScp::Sentinel.resume_from(52, "TOK") # first read ended inside the token
      SsmScp::Sentinel.scan(buf.to_slice, "TOK", from).should eq 12
    end

    it "does not raise when the window starts inside a multibyte character" do
      prefix = "é" * 40
      SsmScp::Sentinel.scan((prefix + "TOK0\n").to_slice, "TOK").should eq 0
    end

    it "does not raise on invalid UTF-8 in the output" do
      buf = Bytes[0xff, 0xfe, 0x54, 0x4f, 0x4b, 0x31]
      SsmScp::Sentinel.scan(buf, "TOK").should eq 1
    end

    it "treats regex metacharacters in the sentinel literally" do
      SsmScp::Sentinel.scan("a.b0".to_slice, "a.b").should eq 0
      SsmScp::Sentinel.scan("axb0".to_slice, "a.b").should be_nil
    end
  end

  describe ".port" do
    it "parses PORT=n followed by a newline" do
      SsmScp::Sentinel.port("PORT=41234\r\n").should eq 41234
      SsmScp::Sentinel.port("[1] 99\r\nPORT=5\n").should eq 5
    end

    it "ignores ANSI noise around it" do
      SsmScp::Sentinel.port("\e[?2004lPORT=8080\r\n\e[0m").should eq 8080
    end

    it "waits for the newline so a split read cannot truncate the port" do
      SsmScp::Sentinel.port("PORT=412").should be_nil
      SsmScp::Sentinel.port("PORT=41234").should be_nil
    end

    it "does not match the echoed python source (PORT= followed by a quote)" do
      SsmScp::Sentinel.port("sys.stdout.write('PORT='+str(1)+'\\n')\n").should be_nil
    end

    it "returns nil on empty input" do
      SsmScp::Sentinel.port("").should be_nil
    end
  end
end

describe "PTY read helpers" do
  it "pty_read_chunk returns data" do
    r, w = IO.pipe
    w << "hello"
    w.flush
    String.new(pty_read_chunk(r, 0.5)).should eq "hello"
    r.close
    w.close
  end

  it "pty_read_chunk returns empty on timeout" do
    r, w = IO.pipe
    pty_read_chunk(r, 0.05).should be_empty
    r.close
    w.close
  end

  it "pty_read_chunk raises when the other side closed (EOF)" do
    r, w = IO.pipe
    w.close
    expect_raises(SsmScp::Error, "remote shell closed unexpectedly") { pty_read_chunk(r, 0.5) }
    r.close
  end

  describe "wait_for_prompt" do
    it "succeeds on a bash prompt, ANSI or not" do
      {"ssm-user@ip-10-0-0-1:~$ ", "sh-5.2$ ", "root# ", "\e[?2004h[ec2-user@x ~]$ \e[0m"}.each do |prompt|
        r, w = IO.pipe
        w << "Starting session with SessionId: abc\r\n" << prompt
        w.flush
        ok, text = wait_for_prompt(r, 1.0)
        ok.should be_true
        text.should eq ""
        r.close
        w.close
      end
    end

    it "times out and returns what it saw" do
      r, w = IO.pipe
      w << "Starting session with SessionId: abc\r\n"
      w.flush
      ok, text = wait_for_prompt(r, 0.3)
      ok.should be_false
      text.should eq "Starting session with SessionId: abc"
      r.close
      w.close
    end

    it "assembles a prompt delivered in several chunks" do
      r, w = IO.pipe
      spawn do
        w << "banner\r\n"
        w.flush
        sleep 0.1.seconds
        w << "user@host:~"
        w.flush
        sleep 0.1.seconds
        w << "$ "
        w.flush
      end
      ok, _ = wait_for_prompt(r, 2.0)
      ok.should be_true
      r.close
      w.close
    end

    it "raises if the session closes while waiting" do
      r, w = IO.pipe
      w.close
      expect_raises(SsmScp::Error, /closed unexpectedly/) { wait_for_prompt(r, 1.0) }
      r.close
    end
  end

  describe "read_until_sentinel" do
    it "returns the exit code even when the token is split across reads" do
      r, w = IO.pipe
      spawn do
        w << "noise\r\nSSMRSHabc"
        w.flush
        sleep 0.15.seconds
        w << "def3\r\n"
        w.flush
      end
      read_until_sentinel(r, "SSMRSHabcdef", 2.0).should eq 3
      r.close
      w.close
    end

    it "finds the sentinel even when the same read carries lots of later output" do
      r, w = IO.pipe
      w << "TOK0\n" << "[1] 12345 job notice and more text" << ("y" * 3000)
      w.flush
      read_until_sentinel(r, "TOK", 1.0).should eq 0
      r.close
      w.close
    end

    it "finds the sentinel after a large amount of earlier output, over many reads" do
      r, w = IO.pipe
      spawn do
        50.times do
          w << ("z" * 1000)
          w.flush
        end
        w << "TOK4\n"
        w.flush
      end
      read_until_sentinel(r, "TOK", 5.0).should eq 4
      r.close
      w.close
    end

    it "returns -1 on timeout" do
      r, w = IO.pipe
      w << "no sentinel\n"
      w.flush
      read_until_sentinel(r, "TOK", 0.3).should eq -1
      r.close
      w.close
    end

    it "returns the code of the awaited token, not a stale one" do
      r, w = IO.pipe
      w << "OLD1\nTOK0\n"
      w.flush
      read_until_sentinel(r, "TOK", 1.0).should eq 0
      r.close
      w.close
    end

    it "raises if the pipe closes first" do
      r, w = IO.pipe
      w.close
      expect_raises(SsmScp::Error) { read_until_sentinel(r, "TOK", 1.0) }
      r.close
    end
  end

  describe "read_remote_port" do
    it "returns the port" do
      r, w = IO.pipe
      w << "[1] 4242\r\nPORT=39001\r\n"
      w.flush
      read_remote_port(r, 1.0).should eq 39001
      r.close
      w.close
    end

    it "is not fooled by a port split over two reads" do
      r, w = IO.pipe
      spawn do
        w << "PORT=390"
        w.flush
        sleep 0.15.seconds
        w << "01\r\n"
        w.flush
      end
      read_remote_port(r, 2.0).should eq 39001
      r.close
      w.close
    end

    it "returns nil on timeout" do
      r, w = IO.pipe
      read_remote_port(r, 0.3).should be_nil
      r.close
      w.close
    end
  end
end
