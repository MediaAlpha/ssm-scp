require "./spec_helper"

describe "direct mode: rsync flag assembly" do
  it "builds the rsh command from options in a fixed order" do
    o = parse("--region", "us-west-2", "--profile", "p", "--sudo", "--compress-level=3", "-v", "a", "b")
    o.rsh_command("/usr/local/bin/ssm-scp").should eq(
      "/usr/local/bin/ssm-scp --region us-west-2 --profile p --sudo --compress-level=3 -v")
  end

  it "omits profile, sudo and -v when unset" do
    parse("a", "b", region: "r").rsh_command("x").should eq "x --region r --compress-level=6"
  end

  it "omits --region too when no region is set" do
    parse("a", "b", region: nil).rsh_command("x").should eq "x --compress-level=6"
    parse("-v", "a", "b", region: nil, profile: "p").rsh_command("x").should eq "x --profile p --compress-level=6 -v"
  end

  describe "rsh command quoting (rsync splits on spaces, honours quotes)" do
    it "single-quotes a part with whitespace" do
      parse("a", "b", region: "r").rsh_command("/Users/me/My Tools/ssm-scp").should eq(
        "'/Users/me/My Tools/ssm-scp' --region r --compress-level=6")
    end

    it "doubles a literal single quote inside the quotes" do
      parse("a", "b", region: "r", profile: "it's me").rsh_command("x").should eq(
        "x --region r --profile 'it''s me' --compress-level=6")
    end

    it "quotes a part that only contains a quote or double quote" do
      SsmScp::Options.rsh_quote("a'b").should eq "'a''b'"
      SsmScp::Options.rsh_quote(%(a"b)).should eq %('a"b')
      SsmScp::Options.rsh_quote("plain-1/x.y").should eq "plain-1/x.y"
    end

    it "round-trips through rsync's splitting rules" do
      split = ->(cmd : String) do
        words = [] of String
        cur = IO::Memory.new
        in_word = false
        quote : Char? = nil
        chars = cmd.chars
        i = 0
        while i < chars.size
          c = chars[i]
          if q = quote
            if c == q
              if chars[i + 1]? == q
                cur << c
                i += 1
              else
                quote = nil
              end
            else
              cur << c
            end
          elsif c == '\'' || c == '"'
            quote = c
            in_word = true
          elsif c == ' '
            if in_word
              words << cur.to_s
              cur.clear
              in_word = false
            end
          else
            cur << c
            in_word = true
          end
          i += 1
        end
        words << cur.to_s if in_word
        words
      end
      o = parse("a", "b", region: "r", profile: "my 'odd' prof")
      split.call(o.rsh_command("/p a/th/ssm-scp")).should eq(
        ["/p a/th/ssm-scp", "--region", "r", "--profile", "my 'odd' prof", "--compress-level=6"])
    end
  end

  it "does not forward --chown/--chmod/--rsync-arg to the rsh command" do
    o = parse("--sudo", "--chown", "u:g", "--chmod", "F440", "--rsync-arg", "-n", "a", "b")
    o.rsh_command("x").should_not contain "chown"
    o.rsh_command("x").should_not contain "chmod"
    o.rsh_command("x").should_not contain "-n"
  end

  it "base flags with a modern local rsync" do
    flags = parse("a", "b").rsync_flags(true)
    flags.should eq ["--progress", "-h", "-z", "--compress-level=6", "--skip-compress=#{SKIP_COMPRESS}"]
  end

  it "omits --skip-compress for an old local rsync" do
    parse("a", "b").rsync_flags(false).should eq ["--progress", "-h", "-z", "--compress-level=6"]
  end

  it "adds -v only when verbose, after --skip-compress" do
    flags = parse("-v", "a", "b").rsync_flags(true)
    flags.last.should eq "-v"
    flags[-2].should start_with "--skip-compress="
  end

  it "orders -v, --chown, --chmod, then --rsync-arg values" do
    o = parse("-v", "--sudo", "--rsync-arg", "--dry-run", "--chmod", "0440",
      "--chown", "root:root", "--rsync-arg", "--bwlimit=5", "a", "b")
    o.rsync_flags(false).should eq [
      "--progress", "-h", "-z", "--compress-level=6", "-v",
      "--chown=root:root", "--chmod=0440", "--dry-run", "--bwlimit=5",
    ]
  end

  it "--chmod alone needs no sudo" do
    parse("--chmod", "F440", "a", "b").rsync_flags(false).should contain "--chmod=F440"
  end

  it "extra rsync args come last so they can override" do
    flags = parse("--rsync-arg", "--no-compress", "a", "b").rsync_flags(true)
    flags.last.should eq "--no-compress"
  end

  it "assembles the full argv: -e, flags, `--`, then positional args untouched" do
    o = parse("--sudo", "--chmod", "0644", "i-1:/src", "/dst")
    argv = o.rsync_argv("/bin/ssm-scp", false, o.rest)
    argv.should eq [
      "-e", "/bin/ssm-scp --region us-east-1 --sudo --compress-level=6",
      "--progress", "-h", "-z", "--compress-level=6", "--chmod=0644",
      "--", "i-1:/src", "/dst",
    ]
  end

  it "passes several sources and a leading-dash file name after `--`" do
    o = parse("--", "-x.txt", "b.txt", "i-1:/dst/")
    argv = o.rsync_argv("x", false, o.rest)
    argv.last(4).should eq ["--", "-x.txt", "b.txt", "i-1:/dst/"]
    argv.index!("--").should be > argv.index!("--compress-level=6")
  end

  it "does not re-quote positional args that contain spaces or glob characters" do
    o = parse("my host:/a b/*", "/tmp/x y")
    o.rsync_argv("x", false, o.rest).last(3).should eq ["--", "my host:/a b/*", "/tmp/x y"]
  end
end

describe "SKIP_COMPRESS" do
  it "is a colon separated list of unique extensions without dots" do
    exts = SKIP_COMPRESS.split(':')
    exts.uniq.size.should eq exts.size
    exts.each(&.should(match(/\A[a-z0-9]+\z/)))
    {"zip", "gz", "zst", "png", "mp4"}.each { |ext| exts.should contain ext }
  end
end
