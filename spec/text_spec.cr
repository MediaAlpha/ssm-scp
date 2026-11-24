require "./spec_helper"

describe "shell_escape" do
  it "single-quotes plain strings" do
    shell_escape("/var/log/app.log").should eq "'/var/log/app.log'"
  end

  it "escapes embedded single quotes" do
    shell_escape("it's").should eq "'it'\\''s'"
    shell_escape("'").should eq "''\\'''"
  end

  it "leaves a bare ~ alone" do
    shell_escape("~").should eq "~"
  end

  it "keeps a leading ~/ unquoted so the shell expands it" do
    shell_escape("~/dir/file").should eq "~/'dir/file'"
    shell_escape("~/").should eq "~/''"
  end

  it "quotes ~user and a ~ in the middle" do
    shell_escape("~bob/x").should eq "'~bob/x'"
    shell_escape("/a/~/b").should eq "'/a/~/b'"
  end

  it "neutralises shell metacharacters" do
    shell_escape("a b;$(rm -rf /)`x`").should eq "'a b;$(rm -rf /)`x`'"
    shell_escape("").should eq "''"
  end

  it "does not touch double quotes or backslashes" do
    shell_escape(%q(a"b\c)).should eq %q('a"b\c')
  end

  it "round-trips through /bin/sh" do
    # Local, offline: only runs `sh -c printf`, no network or remote host.
    ["a b", "it's", "$HOME", "x;y", "*", "a\\b", "\"q\""].each do |value|
      buf = IO::Memory.new
      Process.run("/bin/sh", ["-c", "printf %s #{shell_escape(value)}"], output: buf)
      buf.to_s.should eq value
    end
  end
end

describe "strip_ansi" do
  it "removes colour and cursor sequences" do
    strip_ansi("\e[31mred\e[0m").should eq "red"
    strip_ansi("\e[2K\e[1Gprompt").should eq "prompt"
    strip_ansi("\e[?2004h$ ").should eq "$ "
  end

  it "normalises CRLF and CR to LF" do
    strip_ansi("a\r\nb\rc\n").should eq "a\nb\nc\n"
  end

  it "leaves plain text unchanged" do
    strip_ansi("hello world").should eq "hello world"
    strip_ansi("").should eq ""
  end

  it "does not raise on invalid UTF-8" do
    bad = String.new(Bytes[0x61, 0xe2, 0x82])
    cleaned = strip_ansi(bad)
    cleaned.valid_encoding?.should be_true
    cleaned.should start_with "a"
  end

  it "strips OSC sequences ended by BEL or ESC backslash" do
    strip_ansi("\e]0;title\a$ ").should eq "$ "
    strip_ansi("\e]2;ec2-user@host: ~\e\\[ec2-user@host ~]$ ").should eq "[ec2-user@host ~]$ "
    strip_ansi("\e]0;a\ab\e]7;file:///x\a").should eq "b"
  end
end

describe "rsync_zstd_capable?" do
  {
    "rsync  version 3.2.7  protocol version 31"                      => true,
    "rsync  version 3.2.0  protocol version 31"                      => true,
    "rsync  version 3.3.0  protocol version 31"                      => true,
    "rsync  version 3.4.1  protocol version 32"                      => true,
    "rsync  version 4.0.0"                                           => true,
    "rsync  version 10.1.0"                                          => true,
    "rsync version 3.2.0pre1 protocol version 31"                    => true,
    "rsync  version 3.1.3  protocol version 31"                      => false,
    "rsync  version 3.0.9  protocol version 30"                      => false,
    "rsync  version 2.6.9  protocol version 29"                      => false,
    "openrsync: protocol version 29\nrsync version 2.6.9 compatible" => false,
    "rsync version 3.10.0"                                           => true,
    "rsync version 3.1.10"                                           => false,
    ""                                                               => false,
    "garbage"                                                        => false,
    "rsync: command not found"                                       => false,
    "version 3.2.7"                                                  => false,
  }.each do |text, expected|
    it "#{text.inspect} => #{expected}" do
      rsync_zstd_capable?(text).should eq expected
    end
  end

  it "reads the version from a multi-line banner" do
    banner = "rsync  version 3.2.7  protocol version 31\nCopyright (C) 1996-2022\nCapabilities:\n    zstd\n"
    rsync_zstd_capable?(banner).should be_true
  end
end

describe "new_token" do
  it "is prefixed, unique and shell/regex safe" do
    a = new_token
    b = new_token
    a.should_not eq b
    a.should start_with SENTINEL_PFX
    a.should match(/\ASSMRSH[0-9a-f]{24}\z/)
  end
end

describe "REMOTE_RE" do
  it "matches instance ids and paths" do
    m = REMOTE_RE.match!("i-0abc1234:/remote/path")
    m[1].should eq "i-0abc1234"
    m[2].should eq "/remote/path"
  end

  it "matches Name tags, user@host and empty paths" do
    REMOTE_RE.match!("my-server:/x")[1].should eq "my-server"
    REMOTE_RE.match!("ec2-user@i-1:/x")[1].should eq "ec2-user@i-1"
    REMOTE_RE.match!("host:")[2].should eq ""
    REMOTE_RE.match!("host:~/dir")[2].should eq "~/dir"
  end

  it "splits at the first colon so paths may contain colons" do
    m = REMOTE_RE.match!("host:/a:b:c")
    m[1].should eq "host"
    m[2].should eq "/a:b:c"
  end

  it "does not match plain local paths" do
    {"/etc/passwd", "./file", "file.txt", "../x", "dir/sub", "", "-v"}.each do |local|
      REMOTE_RE.match(local).should be_nil
    end
  end

  it "does not match absolute paths even when they contain a colon" do
    REMOTE_RE.match("/tmp/a:b").should be_nil
    REMOTE_RE.match(":x").should be_nil
  end

  it "treats Windows-like drive paths as remote (as rsync does)" do
    REMOTE_RE.match!("C:\\Users\\me")[1].should eq "C"
    REMOTE_RE.match!("C:/Users/me")[1].should eq "C"
  end

  it "treats a slash before the first colon as local, like rsync" do
    REMOTE_RE.match("./a:b").should be_nil
    REMOTE_RE.match("dir/sub:file").should be_nil
    REMOTE_RE.match("/abs/dir:file").should be_nil
    REMOTE_RE.match("../x:y").should be_nil
    SsmScp::Resolve.remote_spec?("dir/sub:file").should be_false
    SsmScp::Resolve.remote_spec?("./a:b").should be_false
  end

  it "still matches a colon before any slash" do
    REMOTE_RE.match!("host:dir/sub:file")[2].should eq "dir/sub:file"
    REMOTE_RE.match!("user@host:/x")[1].should eq "user@host"
  end
end

describe SsmScp::Resolve do
  describe ".instance_id?" do
    it "accepts lowercase hex ids" do
      SsmScp::Resolve.instance_id?("i-0abc1234").should be_true
      SsmScp::Resolve.instance_id?("i-0123456789abcdef0").should be_true
    end

    it "rejects Name tags and malformed ids" do
      {"my-server", "i-", "I-0abc", "i-0ABC", "i-xyz", "web-i-0abc", "i-0abc:/x", ""}.each do |name|
        SsmScp::Resolve.instance_id?(name).should be_false
      end
    end

    it "known quirk: a Name tag that looks like hex is taken as an id" do
      SsmScp::Resolve.instance_id?("i-beef").should be_true
    end
  end

  describe ".host_from_arg" do
    it "strips user@" do
      SsmScp::Resolve.host_from_arg("ec2-user@i-0abc").should eq "i-0abc"
      SsmScp::Resolve.host_from_arg("i-0abc").should eq "i-0abc"
      SsmScp::Resolve.host_from_arg("a@b@c").should eq "b@c"
    end
  end

  describe ".ec2_lookup_args" do
    it "builds a describe-instances call without a profile" do
      args = SsmScp::Resolve.ec2_lookup_args("web", "us-west-2", nil)
      args.first(2).should eq ["ec2", "describe-instances"]
      args.should contain "Name=tag:Name,Values=web"
      args.should contain "Name=instance-state-name,Values=running"
      args.last(2).should eq ["--region", "us-west-2"]
      args.should_not contain "--profile"
    end

    it "passes no --region when none is set" do
      args = SsmScp::Resolve.ec2_lookup_args("web", nil, nil)
      args.should_not contain "--region"
      args.last(2).should eq ["--output", "text"]
      SsmScp::Resolve.ec2_lookup_args("web", nil, "prod").last(2).should eq ["--profile", "prod"]
    end

    it "appends --profile when set" do
      SsmScp::Resolve.ec2_lookup_args("web", "r", "prod").last(2).should eq ["--profile", "prod"]
    end
  end

  describe ".parse_ids" do
    it "splits on any whitespace" do
      SsmScp::Resolve.parse_ids("i-1\ti-2\ni-3  \n").should eq ["i-1", "i-2", "i-3"]
      SsmScp::Resolve.parse_ids("").should be_empty
      SsmScp::Resolve.parse_ids("\n").should be_empty
    end
  end

  describe ".check_name!" do
    it "accepts ordinary Name tags" do
      {"web-1", "my server", "a.b_c:d"}.each { |name| SsmScp::Resolve.check_name!(name) }
    end

    it "rejects the EC2 filter's list separator and wildcards" do
      {"a,b", "web-*", "web-?", "*"}.each do |name|
        expect_raises(SsmScp::Error, /use the instance id/) { SsmScp::Resolve.check_name!(name) }
      end
    end
  end

  describe "aws arguments" do
    it "adds --region and --profile only when set" do
      SsmScp::Resolve.aws_common_args(nil, nil).should be_empty
      SsmScp::Resolve.aws_common_args("r", nil).should eq ["--region", "r"]
      SsmScp::Resolve.aws_common_args(nil, "p").should eq ["--profile", "p"]
      SsmScp::Resolve.aws_common_args("r", "p").should eq ["--region", "r", "--profile", "p"]
    end

    it "builds the shell session and port-forward calls" do
      SsmScp::Resolve.session_args("i-1", nil, nil).should eq ["ssm", "start-session", "--target", "i-1"]
      SsmScp::Resolve.session_args("i-1", "us-west-2", "p").should eq(
        ["ssm", "start-session", "--target", "i-1", "--region", "us-west-2", "--profile", "p"])
      fwd = SsmScp::Resolve.forward_args("i-1", 5000, 6000, nil, nil)
      fwd.should_not contain "--region"
      fwd.should contain "AWS-StartPortForwardingSession"
      JSON.parse(fwd[fwd.index!("--parameters") + 1]).should eq(
        JSON.parse(%({"portNumber":["6000"],"localPortNumber":["5000"]})))
      SsmScp::Resolve.forward_args("i-1", 1, 2, "r", nil).last(2).should eq ["--region", "r"]
    end
  end

  describe ".direct_mode?" do
    it "needs two or more positional args, at least one remote" do
      SsmScp::Resolve.direct_mode?(["f", "i-1:/x"]).should be_true
      SsmScp::Resolve.direct_mode?(["i-1:/x", "."]).should be_true
      SsmScp::Resolve.direct_mode?(["a:/x", "b:/y"]).should be_true
      SsmScp::Resolve.direct_mode?(["f", "g", "i-1:/x"]).should be_true
      SsmScp::Resolve.direct_mode?(["i-1:/x", "i-1:/y", "dst"]).should be_true
    end

    it "is false for local copies, a single arg and rsh mode" do
      SsmScp::Resolve.direct_mode?(["a", "b"]).should be_false
      SsmScp::Resolve.direct_mode?(["a", "b", "c"]).should be_false
      SsmScp::Resolve.direct_mode?(["i-1:/x"]).should be_false
      SsmScp::Resolve.direct_mode?([] of String).should be_false
      SsmScp::Resolve.direct_mode?(["i-1", "rsync", "--server", "."]).should be_false
    end

    it "treats --server anywhere as rsh mode, even next to something colon-ish" do
      SsmScp::Resolve.direct_mode?(["i-1", "rsync", "--server", "--sender", ".", "/a:b"]).should be_false
      SsmScp::Resolve.direct_mode?(["i-1", "sudo", "rsync", "--server", "."]).should be_false
    end
  end
end
