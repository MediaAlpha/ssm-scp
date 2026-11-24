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

  describe ".check_command readability (run with /bin/sh)" do
    it "returns 1 for a file that exists but is not readable" do
      pending!("running as root: chmod 000 does not block root") if LibC.getuid == 0
      with_tmp_dir do |dir|
        File.write(dir / "secret", "x")
        File.chmod(dir / "secret", 0o000)
        escaped = shell_escape((dir / "secret").to_s)
        snippet_rc(SsmScp::Remote.check_command(escaped, false, SPEC_TOKEN), SYS_PATH).should eq 1
      end
    end

    it "returns 1 if any of several paths is unreadable, 2 if only missing, 0 if all ok" do
      pending!("running as root: chmod 000 does not block root") if LibC.getuid == 0
      with_tmp_dir do |dir|
        File.write(dir / "ok", "x")
        File.write(dir / "secret", "x")
        File.chmod(dir / "secret", 0o000)
        ok, secret, gone = {"ok", "secret", "gone"}.map { |name| shell_escape((dir / name).to_s) }
        rc = ->(paths : String) { snippet_rc(SsmScp::Remote.check_command(paths, false, SPEC_TOKEN), SYS_PATH) }
        rc.call("#{ok}").should eq 0
        rc.call("#{ok} #{secret}").should eq 1
        rc.call("#{secret} #{gone}").should eq 1
        rc.call("#{gone} #{secret}").should eq 1
        rc.call("#{ok} #{gone}").should eq 2
      end
    end

    it "expands globs (left unquoted by rsync's escaping)" do
      with_tmp_dir do |dir|
        File.write(dir / "a1.txt", "x")
        File.write(dir / "a2.txt", "x")
        snippet_rc(SsmScp::Remote.check_command("#{shell_escape(dir.to_s)}/a*.txt", false, SPEC_TOKEN), SYS_PATH).should eq 0
        snippet_rc(SsmScp::Remote.check_command("#{shell_escape(dir.to_s)}/b*.txt", false, SPEC_TOKEN), SYS_PATH).should eq 2
      end
    end
  end

  describe ".check_command failure frames (run with /bin/sh)" do
    it "names only the failing paths, after the token, and the rc last" do
      with_tmp_dir do |dir|
        File.write(dir / "ok", "x")
        paths = {"ok", "gone one", "gone2"}.map { |name| shell_escape((dir / name).to_s) }.join(" ")
        shown = run_snippet(SsmScp::Remote.check_command(paths, false, SPEC_TOKEN), SYS_PATH)
        SsmScp::Sentinel.check(shown, SPEC_TOKEN).should eq({2, [{2, (dir / "gone one").to_s}, {2, (dir / "gone2").to_s}]})
        shown.should_not contain((dir / "ok").to_s)
      end
    end

    it "shows the real path a glob matched" do
      pending!("running as root: chmod 000 does not block root") if LibC.getuid == 0
      with_tmp_dir do |dir|
        File.write(dir / "secret.log", "x")
        File.chmod(dir / "secret.log", 0o000)
        File.write(dir / "fine.log", "x")
        shown = run_snippet(SsmScp::Remote.check_command("#{shell_escape(dir.to_s)}/*.log", false, SPEC_TOKEN), SYS_PATH)
        SsmScp::Sentinel.check(shown, SPEC_TOKEN).should eq({1, [{1, (dir / "secret.log").to_s}]})
      end
    end

    it "handles a path that starts with a dash" do
      with_tmp_dir do |dir|
        Dir.cd(dir.to_s) do
          File.write("-x.txt", "x")
          snippet_rc(SsmScp::Remote.check_command("-x.txt", false, SPEC_TOKEN), SYS_PATH).should eq 0
          shown = run_snippet("cd #{shell_escape(dir.to_s)}; " + SsmScp::Remote.check_command("-y.txt", false, SPEC_TOKEN), SYS_PATH)
          SsmScp::Sentinel.check(shown, SPEC_TOKEN).should eq({2, [{2, "-y.txt"}]})
        end
      end
    end
  end

  describe ".check_command with sudo (fake sudo on PATH, run with /bin/sh)" do
    # `sudo -n` runs the command as it is; a second script plays a sudo that
    # wants a password, a third an ls that is denied.
    it "returns 0 / 2 for an existing / missing path and never says 'password' for a missing one" do
      with_tmp_dir do |dir|
        write_script(dir / "sudo", %([ "$1" = -n ] && shift; exec "$@"))
        File.write(dir / "here", "x")
        path = "#{dir}:#{SYS_PATH}"
        ok = shell_escape((dir / "here").to_s)
        gone = shell_escape((dir / "gone").to_s)
        snippet_rc(SsmScp::Remote.check_command(ok, true, SPEC_TOKEN), path).should eq 0
        shown = run_snippet(SsmScp::Remote.check_command("#{ok} #{gone}", true, SPEC_TOKEN), path)
        SsmScp::Sentinel.check(shown, SPEC_TOKEN).should eq({2, [{2, (dir / "gone").to_s}]})
      end
    end

    it "returns 3 when sudo needs a password, apart from permission denied" do
      with_tmp_dir do |dir|
        write_script(dir / "sudo", %(echo 'sudo: a password is required' >&2; exit 1))
        shown = run_snippet(SsmScp::Remote.check_command("/etc/hostname /etc", true, SPEC_TOKEN), "#{dir}:#{SYS_PATH}")
        SsmScp::Sentinel.check(shown, SPEC_TOKEN).should eq({3, [{3, "/etc/hostname"}, {3, "/etc"}]})
      end
    end

    it "returns 1 for a permission denied ls under sudo" do
      with_tmp_dir do |dir|
        write_script(dir / "sudo", %(echo "ls: cannot access '$7': Permission denied" >&2; exit 2))
        shown = run_snippet(SsmScp::Remote.check_command("/root/x", true, SPEC_TOKEN), "#{dir}:#{SYS_PATH}")
        SsmScp::Sentinel.check(shown, SPEC_TOKEN).should eq({1, [{1, "/root/x"}]})
      end
    end

    it "lets a sudo failure win over other failures, and permission denied over missing" do
      with_tmp_dir do |dir|
        write_script(dir / "sudo", "case \"$7\" in *a) echo 'sudo: no tty present' >&2; exit 1;; " \
                                   "*b) echo 'ls: x: Permission denied' >&2; exit 2;; " \
                                   "*) echo 'ls: x: No such file or directory' >&2; exit 2;; esac")
        {"/p/c /p/b /p/a" => 3, "/p/c /p/b" => 1, "/p/c" => 2}.each do |paths, expected|
          snippet_rc(SsmScp::Remote.check_command(paths, true, SPEC_TOKEN), "#{dir}:#{SYS_PATH}").should eq expected
        end
      end
    end

    it "does not confuse a path with 'sudo:' in it for a sudo failure" do
      with_tmp_dir do |dir|
        write_script(dir / "sudo", %([ "$1" = -n ] && shift; exec "$@"))
        shown = run_snippet(SsmScp::Remote.check_command("/no/sudo:here", true, SPEC_TOKEN), "#{dir}:#{SYS_PATH}")
        SsmScp::Sentinel.check(shown, SPEC_TOKEN).should eq({2, [{2, "/no/sudo:here"}]})
      end
    end
  end

  {"bash" => ["--norc", "--noprofile", "-c"], "dash" => ["-c"], "sh" => ["-c"]}.each do |name, shell_args|
    describe ".preflight_command (run with #{name})" do
      shell = name == "dash" && File.exists?("/bin/dash") ? "/bin/dash" : Process.find_executable(name)

      # PATH holds only the temp dir; builtins (command, printf, cd) still work.
      run = ->(dir : Path) do
        snippet_rc(SsmScp::Remote.preflight_command(SPEC_TOKEN), dir.to_s, [shell.to_s] + shell_args)
      end

      it "emits the token and 0 when rsync, python3 and base64 are present" do
        pending!("#{name} not found") unless shell
        with_tmp_dir do |dir|
          {"rsync", "python3", "base64"}.each { |cmd| write_script(dir / cmd, "exit 0") }
          run.call(dir).should eq 0
        end
      end

      it "returns 1 when rsync is missing, 2 when python3 is, 3 when base64 is (in that order)" do
        pending!("#{name} not found") unless shell
        with_tmp_dir do |dir|
          write_script(dir / "python3", "exit 0")
          write_script(dir / "base64", "exit 0")
          run.call(dir).should eq 1
          File.delete(dir / "python3")
          run.call(dir).should eq 1
          write_script(dir / "rsync", "exit 0")
          run.call(dir).should eq 2
          write_script(dir / "python3", "exit 0")
          File.delete(dir / "base64")
          run.call(dir).should eq 3
        end
      end

      it "goes to $HOME like ssh does" do
        pending!("#{name} not found") unless shell
        with_tmp_dir do |dir|
          {"rsync", "python3", "base64"}.each { |cmd| write_script(dir / cmd, "exit 0") }
          home = dir / "home"
          Dir.mkdir(home)
          # PATH is the temp dir; the shell starts in "/" and must end up in home.
          cmd = SsmScp::Remote.preflight_command(SPEC_TOKEN) + "pwd -P\n"
          buf = IO::Memory.new
          Process.run(shell.to_s, shell_args + [cmd], env: {"PATH" => dir.to_s, "HOME" => home.to_s},
            clear_env: true, chdir: "/", input: Process::Redirect::Close, output: buf, error: Process::Redirect::Close)
          buf.to_s.lines.last.should eq File.realpath(home.to_s)
        end
      end
    end
  end

  describe ".preflight_command misc" do
    it "is not fooled by an echo of the command line" do
      # Output that merely echoes the command must not yield a result.
      echoed = SsmScp::Remote.preflight_command(SPEC_TOKEN)
      SsmScp::Sentinel.scan(echoed.to_slice, SPEC_TOKEN).should be_nil
    end
  end

  describe ".wrap (run with /bin/sh)" do
    it "delivers awkward bytes (tab, é, quotes, control bytes) exactly" do
      awkward = "a\tb é 'q' \"d\" $x `y` \\z \x01\x02\x1b[A !! end"
      with_tmp_dir do |dir|
        out_file = dir / "out"
        cmd = SsmScp::Remote.wrap("printf %s #{shell_escape(awkward)} > #{shell_escape(out_file.to_s)}")
        run_snippet(cmd, SYS_PATH)
        File.read(out_file).should eq awkward
      end
    end

    it "delivers a long multi-line command through the chunked form" do
      with_tmp_dir do |dir|
        out_file = dir / "out"
        body = "x=0\n" + (1..200).map { |i| "x=$((x+#{i}))" }.join("\n") + "\nprintf %s \"$x\" > #{shell_escape(out_file.to_s)}"
        cmd = SsmScp::Remote.wrap(body, 60)
        cmd.lines.size.should be > 5
        # sh -c with several lines runs them in turn, like typed input.
        run_snippet(cmd, SYS_PATH)
        File.read(out_file).should eq "20100"
      end
    end
  end
end
