require "./spec_helper"

describe SsmScp::Options do
  describe ".parse defaults" do
    it "uses the given region and profile and no flags" do
      o = parse("i-1:/a", "/b", region: "eu-west-1", profile: "prod")
      o.region.should eq "eu-west-1"
      o.profile.should eq "prod"
      o.sudo?.should be_false
      o.verbose?.should be_false
      o.compress_level.should eq 6
      o.chown.should be_nil
      o.chmod.should be_nil
      o.rsync_args.should be_empty
      o.action.should eq SsmScp::Options::Action::Run
      o.rest.should eq ["i-1:/a", "/b"]
    end

    it "default_region follows AWS_REGION, then AWS_DEFAULT_REGION, else nil (no forced region)" do
      saved = {ENV["AWS_REGION"]?, ENV["AWS_DEFAULT_REGION"]?}
      begin
        ENV.delete("AWS_REGION")
        ENV.delete("AWS_DEFAULT_REGION")
        SsmScp::Options.default_region.should be_nil
        ENV["AWS_REGION"] = ""
        SsmScp::Options.default_region.should be_nil
        ENV.delete("AWS_REGION")
        ENV["AWS_DEFAULT_REGION"] = "ap-south-1"
        SsmScp::Options.default_region.should eq "ap-south-1"
        ENV["AWS_REGION"] = "eu-central-1"
        SsmScp::Options.default_region.should eq "eu-central-1"
      ensure
        {"AWS_REGION", "AWS_DEFAULT_REGION"}.each_with_index do |k, i|
          if v = saved[i]
            ENV[k] = v
          else
            ENV.delete(k)
          end
        end
      end
    end
  end

  describe "flags" do
    it "has no region unless one is given" do
      parse("a", "b", region: nil).region.should be_nil
      SsmScp::Options.parse(["a", "b"], nil, nil).region.should be_nil
    end

    it "--region overrides the default" do
      parse("--region", "us-west-2", "a", "b").region.should eq "us-west-2"
    end

    it "--profile overrides the default" do
      parse("--profile", "dev", "a", "b", profile: "prod").profile.should eq "dev"
    end

    it "--sudo" do
      parse("--sudo", "a", "b").sudo?.should be_true
    end

    it "--chown and --chmod take a value" do
      o = parse("--chown", "root:root", "--chmod", "F440", "a", "b")
      o.chown.should eq "root:root"
      o.chmod.should eq "F440"
    end

    it "--rsync-arg is repeatable and keeps order" do
      o = parse("--rsync-arg", "--dry-run", "--rsync-arg", "--bwlimit=10", "a", "b")
      o.rsync_args.should eq ["--dry-run", "--bwlimit=10"]
    end

    it "--rsync-arg takes the next token even if it starts with a dash" do
      parse("--rsync-arg", "-n", "a", "b").rsync_args.should eq ["-n"]
    end

    it "-v and --verbose" do
      parse("-v", "a", "b").verbose?.should be_true
      parse("--verbose", "a", "b").verbose?.should be_true
    end

    it "-l consumes its value (rsync passes -l user)" do
      o = parse("-l", "ec2-user", "i-1", "rsync", "--server")
      o.rest.should eq ["i-1", "rsync", "--server"]
    end

    it "-l at the end with no value is harmless" do
      parse("-l").rest.should be_empty
    end

    it "--compress-level N and --compress-level=N" do
      parse("--compress-level", "3", "a", "b").compress_level.should eq 3
      parse("--compress-level=22", "a", "b").compress_level.should eq 22
      parse("--compress-level=1", "a", "b").compress_level.should eq 1
    end

    it "accepts the --opt=value forms" do
      o = parse("--region=us-west-2", "--profile=dev", "--chown=u:g", "--chmod=F440",
        "--rsync-arg=--dry-run", "--rsync-arg=--bwlimit=10", "a:b", "c")
      o.region.should eq "us-west-2"
      o.profile.should eq "dev"
      o.chown.should eq "u:g"
      o.chmod.should eq "F440"
      o.rsync_args.should eq ["--dry-run", "--bwlimit=10"]
      o.unknown.should be_empty
      o.rest.should eq ["a:b", "c"]
    end

    it "keeps '=' inside an --opt=value value" do
      parse("--chmod=a=r", "a", "b").chmod.should eq "a=r"
    end

    it "accepts every flag together in any order" do
      o = parse("-v", "--sudo", "--region", "r", "--profile", "p", "--chown", "u:g",
        "--chmod", "0644", "--rsync-arg", "-n", "--compress-level=9", "h:/x", "/y")
      o.verbose?.should be_true
      o.sudo?.should be_true
      o.region.should eq "r"
      o.profile.should eq "p"
      o.chown.should eq "u:g"
      o.chmod.should eq "0644"
      o.rsync_args.should eq ["-n"]
      o.compress_level.should eq 9
      o.rest.should eq ["h:/x", "/y"]
    end
  end

  describe "errors" do
    {"--region", "--profile", "--chown", "--chmod", "--rsync-arg", "--compress-level"}.each do |flag|
      it "#{flag} without a value raises" do
        expect_raises(SsmScp::Error, "missing value for #{flag}") { parse(flag) }
      end
    end

    it "rejects out-of-range compress levels" do
      {"0", "23", "-1", "100"}.each do |v|
        expect_raises(SsmScp::Error, /1–22/) { parse("--compress-level", v) }
        expect_raises(SsmScp::Error, /1–22/) { parse("--compress-level=#{v}") }
      end
    end

    it "rejects non-numeric compress levels instead of crashing or ignoring them" do
      expect_raises(SsmScp::Error, /1–22/) { parse("--compress-level", "abc") }
      expect_raises(SsmScp::Error, /1–22/) { parse("--compress-level=abc") }
      expect_raises(SsmScp::Error, /1–22/) { parse("--compress-level=") }
      expect_raises(SsmScp::Error, /1–22/) { parse("--compress-level", "6x") }
    end

    it "--chown without --sudo is an error when building the rsync flags" do
      o = parse("--chown", "root:root", "a:/x", "b")
      expect_raises(SsmScp::Error, /--chown needs --sudo/) { o.rsync_flags(true) }
      expect_raises(SsmScp::Error, /--chown needs --sudo/) { o.rsync_argv("/x", true, o.rest) }
    end

    it "--chown with --sudo (either order) is fine" do
      parse("--sudo", "--chown", "a:b", "h:/x", "y").rsync_flags(true).should contain "--chown=a:b"
      parse("--chown", "a:b", "--sudo", "h:/x", "y").rsync_flags(true).should contain "--chown=a:b"
    end
  end

  describe "actions" do
    it "-V and --version stop parsing" do
      parse("-V").action.should eq SsmScp::Options::Action::Version
      parse("--version").action.should eq SsmScp::Options::Action::Version
    end

    it "-h and --help stop parsing" do
      parse("-h").action.should eq SsmScp::Options::Action::Help
      parse("--help", "--compress-level", "bad").action.should eq SsmScp::Options::Action::Help
    end

    it "an option value is never treated as an action" do
      parse("--region", "--version").region.should eq "--version"
    end

    it "help text mentions every option" do
      text = SsmScp::Options.help_lines.join("\n")
      {"--region", "--profile", "--sudo", "--chown", "--chmod", "--rsync-arg", "--compress-level",
       "-v, --verbose", "-V, --version", "-h, --help", "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_PROFILE"}.each do |flag|
        text.should contain flag
      end
    end
  end

  describe "positional arguments and --" do
    it "stops at the first non-option" do
      parse("--sudo", "i-1", "rsync", "--server", "-v").rest.should eq ["i-1", "rsync", "--server", "-v"]
    end

    it "does not parse flags after the first positional" do
      o = parse("a:/x", "--sudo")
      o.sudo?.should be_false
      o.rest.should eq ["a:/x", "--sudo"]
    end

    it "drops a leading -- and keeps later dashes" do
      o = parse("--sudo", "--", "-weird:/x", "--", "dst")
      o.sudo?.should be_true
      o.rest.should eq ["-weird:/x", "--", "dst"]
    end

    it "handles an empty command line" do
      SsmScp::Options.parse([] of String, "r", nil).rest.should be_empty
    end

    it "collects unknown options instead of dropping them silently" do
      o = parse("--bogus", "-x", "--sudo", "a", "b")
      o.unknown.should eq ["--bogus", "-x"]
      o.sudo?.should be_true
      o.rest.should eq ["a", "b"]
    end

    it "has no unknown options for a clean command line" do
      parse("--sudo", "a", "b").unknown.should be_empty
    end

    it "treats --sudo=1 as unknown (a flag without a value)" do
      parse("--sudo=1", "a", "b").unknown.should eq ["--sudo=1"]
    end
  end
end
