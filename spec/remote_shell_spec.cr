require "./spec_helper"

SYS_PATH = "/usr/bin:/bin"

describe SsmScp::Remote do
  describe ".check_command (run with /bin/sh)" do
    it "returns 0 for an existing file with a space in its name" do
      with_tmp_dir do |dir|
        File.write(dir / "a file.txt", "x")
        escaped = shell_escape((dir / "a file.txt").to_s)
        snippet_rc(SsmScp::Remote.check_command(escaped, false, SPEC_TOKEN), SYS_PATH).should eq 0
      end
    end

    it "accepts rsync-style backslash escapes" do
      with_tmp_dir do |dir|
        File.write(dir / "a file.txt", "x")
        escaped = (dir / "a file.txt").to_s.gsub(" ", "\\ ")
        snippet_rc(SsmScp::Remote.check_command(escaped, false, SPEC_TOKEN), SYS_PATH).should eq 0
      end
    end

    it "returns 2 for a missing file" do
      with_tmp_dir do |dir|
        escaped = shell_escape((dir / "nope").to_s)
        snippet_rc(SsmScp::Remote.check_command(escaped, false, SPEC_TOKEN), SYS_PATH).should eq 2
      end
    end

    it "returns 1 for a file inside an unreadable directory" do
      pending!("running as root: chmod 000 does not block root") if LibC.getuid == 0
      with_tmp_dir do |dir|
        locked = dir / "locked"
        Dir.mkdir(locked)
        File.write(locked / "f", "x")
        File.chmod(locked, 0o000)
        begin
          escaped = shell_escape((locked / "f").to_s)
          snippet_rc(SsmScp::Remote.check_command(escaped, false, SPEC_TOKEN), SYS_PATH).should eq 1
        ensure
          File.chmod(locked, 0o755)
        end
      end
    end
  end

  describe ".preflight_command (run with bash)" do
    bash = Process.find_executable("bash")

    # PATH holds only the temp dir; builtins (command, printf) still work.
    run = ->(dir : Path) do
      snippet_rc(SsmScp::Remote.preflight_command(SPEC_TOKEN), dir.to_s,
        [bash.to_s, "--norc", "--noprofile", "-c"])
    end

    it "emits the token and 0 when rsync and python3 are present" do
      pending!("bash not found") unless bash
      with_tmp_dir do |dir|
        write_script(dir / "rsync", "exit 0")
        write_script(dir / "python3", "exit 0")
        run.call(dir).should eq 0
      end
    end

    it "returns 1 when rsync is missing" do
      pending!("bash not found") unless bash
      with_tmp_dir do |dir|
        write_script(dir / "python3", "exit 0")
        run.call(dir).should eq 1
      end
    end

    it "returns 2 when python3 is missing" do
      pending!("bash not found") unless bash
      with_tmp_dir do |dir|
        write_script(dir / "rsync", "exit 0")
        run.call(dir).should eq 2
      end
    end

    it "returns 1 (rsync first) when both are missing" do
      pending!("bash not found") unless bash
      with_tmp_dir do |dir|
        run.call(dir).should eq 1
      end
    end

    it "is not fooled by an echo of the command line" do
      pending!("bash not found") unless bash
      # Output that merely echoes the command must not yield a result.
      echoed = SsmScp::Remote.preflight_command(SPEC_TOKEN)
      SsmScp::Sentinel.scan(echoed.to_slice, SPEC_TOKEN).should be_nil
    end
  end
end
