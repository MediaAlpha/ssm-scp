require "./spec_helper"
require "digest/sha256"

# End-to-end specs of ssm-scp.cr itself, offline: a fake `aws` on PATH
# (spec/support/bin/aws) stands in for AWS.  Its "remote shell" is a local
# interactive bash on the PTY and its port-forward is a small python TCP
# relay, so the real script runs all three phases, with a real local rsync on
# both ends.  The binary is compiled once per spec run.  Skipped when python3,
# rsync or bash are missing.

module E2E
  SUPPORT = Path[__DIR__] / "support"
  ROOT    = Path[__DIR__].parent

  @@binary : String?

  def self.tools_missing : String?
    {"python3", "rsync", "bash", "base64", "crystal"}.each do |tool|
      return "#{tool} not found" unless Process.find_executable(tool)
    end
    nil
  end

  def self.binary : String
    @@binary ||= build
  end

  private def self.build : String
    dir = File.join(Dir.tempdir, "ssm-scp-e2e-bin-#{Random::Secure.hex(6)}")
    Dir.mkdir_p(dir)
    at_exit { FileUtils.rm_rf(dir) }
    out_path = File.join(dir, "ssm-scp")
    err = IO::Memory.new
    status = Process.run("crystal", ["build", (ROOT / "ssm-scp.cr").to_s, "-o", out_path, "--no-debug"],
      chdir: ROOT.to_s, output: Process::Redirect::Close, error: err)
    raise "building ssm-scp.cr failed:\n#{err}" unless status.success?
    out_path
  end

  record Result, code : Int32, stdout : String, err : String

  # One example's world: a fake remote home, a local working directory, and a
  # directory for the fake aws's log and pid files.
  class World
    getter dir : Path
    getter remote : Path
    getter local : Path
    getter fake : Path
    getter lhome : Path
    getter id : String

    def initialize(@dir : Path)
      @remote = @dir / "remote-home"
      @local = @dir / "local"
      @fake = @dir / "fake-aws"
      @lhome = @dir / "local-home"
      @id = "i-0fa#{Random::Secure.hex(6)}"
      {@remote, @local, @fake, @lhome}.each { |path| Dir.mkdir_p(path) }
      File.write(@fake / "aws.log", "")
      File.write(@fake / "pids", "")
    end

    def env(extra : Hash(String, String) = {} of String => String) : Hash(String, String)
      {
        "PATH"         => "#{SUPPORT / "bin"}:#{ENV["PATH"]}",
        "FAKE_AWS_DIR" => @fake.to_s,
        "FAKE_HOME"    => @remote.to_s,
        "FAKE_CWD"     => "/",
        "HOME"         => @lhome.to_s,
        "LC_ALL"       => "C",
        "LANG"         => "C",
      }.merge(extra)
    end

    def start(args : Array(String), extra_env : Hash(String, String) = {} of String => String,
              unset : Array(String) = [] of String, stdin : Process::Redirect = Process::Redirect::Close) : Process
      full = env(extra_env)
      unset.each { |name| full.delete(name) }
      Process.new(E2E.binary, args, env: full, clear_env: true, chdir: @local.to_s,
        input: stdin, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
    end

    def run(args : Array(String), extra_env : Hash(String, String) = {} of String => String,
            unset : Array(String) = [] of String, timeout : Time::Span = 90.seconds) : Result
      proc = start(args, extra_env, unset)
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      done = Channel(Nil).new(2)
      spawn { IO.copy(proc.output, out_io) rescue nil; done.send(nil) }
      spawn { IO.copy(proc.error, err_io) rescue nil; done.send(nil) }
      waiter = Channel(Process::Status).new(1)
      spawn { waiter.send(proc.wait) }
      status = select
      when s = waiter.receive then s
      when timeout(timeout)
        proc.signal(Signal::KILL) rescue nil
        raise "ssm-scp timed out after #{timeout}: #{args.inspect}\nstderr so far: #{err_io}"
      end
      2.times { done.receive }
      Result.new(status.exit_code, out_io.to_s, err_io.to_s)
    end

    def aws_log : String
      File.read(@fake / "aws.log")
    end

    def pids : Array(Int32)
      File.read(@fake / "pids").split.compact_map(&.to_i?)
    end

    # True once every process the fake aws started is gone (it polls: the
    # processes are reaped by init after we kill them).
    def all_gone?(within : Time::Span = 6.seconds) : Bool
      deadline = Time.instant + within
      loop do
        return true if pids.none? { |pid| Process.exists?(pid) }
        return false if Time.instant > deadline
        sleep 0.1.seconds
      end
    end

    def kill_leftovers : Nil
      pids.each { |pid| Process.signal(Signal::KILL, pid) rescue nil }
    end
  end

  def self.with_world(&)
    with_tmp_dir do |dir|
      world = World.new(dir)
      begin
        yield world
      ensure
        world.kill_leftovers
      end
    end
  end

  # Reads lines from `io` until one contains `text`; raises on timeout/EOF.
  def self.wait_for_line(io : IO::FileDescriptor, text : String, timeout : Time::Span = 40.seconds) : String
    seen = IO::Memory.new
    io.read_timeout = timeout
    while line = io.gets
      seen << line << '\n'
      return seen.to_s if line.includes?(text)
    end
    raise "never saw #{text.inspect}; got:\n#{seen}"
  rescue IO::TimeoutError
    raise "timed out waiting for #{text.inspect}; got:\n#{seen}"
  end

  def self.sha(path : Path | String) : String
    Digest::SHA256.hexdigest(File.read(path.to_s))
  end

  # A remote command (for rsh mode) that records its pid, then sleeps.
  def self.sleeper(world : World, seconds : Int32 = 30) : String
    script = world.dir / "sleeper.sh"
    File.write(script, "#!/bin/sh\necho $$ > #{world.dir}/child.pid\nexec sleep #{seconds}\n", perm: 0o755)
    script.to_s
  end

  def self.kill_sleeper(world : World) : Nil
    path = world.dir / "child.pid"
    if File.exists?(path) && (pid = File.read(path).strip.to_i?)
      Process.signal(Signal::KILL, pid) rescue nil
    end
  end
end

describe "ssm-scp end to end (fake aws)" do
  skip = E2E.tools_missing

  # The sleeper never ends by itself, so do not wait long (after a signal
  # ssm-scp waits for the remote command to end once the tunnel is closed).
  quick_stop = {"SSM_SCP_REMOTE_WAIT" => "1"}

  it "uploads a file; the contents match and progress goes to stderr" do
    pending_if(skip)
    E2E.with_world do |world|
      File.write(world.local / "up.bin", Random::Secure.random_bytes(300_000))
      Dir.mkdir(world.dir / "dst")
      r = world.run(["--", "up.bin", "#{world.id}:#{world.dir}/dst/"])
      r.code.should eq(0), "stderr:\n#{r.err}"
      E2E.sha(world.dir / "dst" / "up.bin").should eq E2E.sha(world.local / "up.bin")
      r.err.should contain "connected"
      r.err.should contain "port-forwarding"
      world.all_gone?.should be_true
    end
  end

  it "downloads a file" do
    pending_if(skip)
    E2E.with_world do |world|
      File.write(world.dir / "big.bin", Random::Secure.random_bytes(300_000))
      Dir.mkdir(world.dir / "got")
      r = world.run(["#{world.id}:#{world.dir}/big.bin", (world.dir / "got").to_s])
      r.code.should eq(0), "stderr:\n#{r.err}"
      E2E.sha(world.dir / "got" / "big.bin").should eq E2E.sha(world.dir / "big.bin")
      world.all_gone?.should be_true
    end
  end

  it "starts in $HOME like ssh: a relative remote path resolves against home" do
    pending_if(skip)
    E2E.with_world do |world|
      File.write(world.remote / "rel.txt", "from home\n")
      Dir.mkdir(world.dir / "got")
      # FAKE_CWD is "/", so only the preflight's `cd` can get the shell home.
      r = world.run(["#{world.id}:rel.txt", (world.dir / "got").to_s])
      r.code.should eq(0), "stderr:\n#{r.err}"
      File.read(world.dir / "got" / "rel.txt").should eq "from home\n"

      r = world.run([(world.dir / "got" / "rel.txt").to_s, "#{world.id}:up-rel.txt"])
      r.code.should eq(0), "stderr:\n#{r.err}"
      File.read(world.remote / "up-rel.txt").should eq "from home\n"
    end
  end

  it "passes the remote rsync's exit status and error text through (23 on an unwritable destination)" do
    pending_if(skip)
    pending!("running as root: chmod does not block root") if LibC.getuid == 0
    E2E.with_world do |world|
      File.write(world.local / "f.txt", "x")
      locked = world.dir / "locked"
      Dir.mkdir(locked)
      File.chmod(locked, 0o555)
      begin
        r = world.run(["--", "f.txt", "#{world.id}:#{locked}/"])
        r.code.should eq(23), "stderr:\n#{r.err}"
        r.err.should contain "Permission denied"
      ensure
        File.chmod(locked, 0o755)
      end
    end
  end

  it "reports a missing remote source before any transfer, with the path and no --sudo hint" do
    pending_if(skip)
    E2E.with_world do |world|
      File.write(world.dir / "here.txt", "x")
      r = world.run(["#{world.id}:#{world.dir}/here.txt", "#{world.id}:#{world.dir}/nope.txt", world.local.to_s])
      r.code.should_not eq 0
      r.err.should contain "cannot access remote path: #{world.dir}/nope.txt "
      r.err.should contain "does not exist on remote"
      r.err.should_not contain "here.txt "
      r.err.should_not contain "--sudo"
      world.all_gone?.should be_true

      r = world.run(["--sudo", "#{world.id}:#{world.dir}/nope.txt", world.local.to_s])
      r.err.should contain "does not exist on remote"
      r.err.should_not contain "try --sudo"
    end
  end

  it "uploads three or more sources at once, including a name starting with a dash, é and a tab" do
    pending_if(skip)
    E2E.with_world do |world|
      names = ["a.txt", "-x.txt", "é.txt", "tab\there.txt"]
      names.each { |name| File.write(world.local / name, "content of #{name.inspect}\n") }
      Dir.mkdir(world.dir / "dst")
      r = world.run(["--", *names, "#{world.id}:#{world.dir}/dst/"])
      r.code.should eq(0), "stderr:\n#{r.err}"
      names.each { |name| File.read(world.dir / "dst" / name).should eq "content of #{name.inspect}\n" }
      r.err.should_not contain "unexpected"
    end
  end

  it "downloads several sources, a dash name, é and a tab included (each pre-checked on the remote)" do
    pending_if(skip)
    E2E.with_world do |world|
      names = ["a b.txt", "-x.txt", "é.txt", "tab\there.txt"]
      names.each { |name| File.write(world.dir / name, "content of #{name.inspect}\n") }
      Dir.mkdir(world.dir / "got")
      r = world.run(names.map { |name| "#{world.id}:#{world.dir}/#{name}" } + [(world.dir / "got").to_s])
      r.code.should eq(0), "stderr:\n#{r.err}"
      names.each { |name| File.read(world.dir / "got" / name).should eq "content of #{name.inspect}\n" }

      # A source that starts with a dash is made relative to the remote home.
      File.write(world.remote / "-y.txt", "dash\n")
      r = world.run(["#{world.id}:./-y.txt", (world.dir / "got").to_s])
      r.code.should eq(0), "stderr:\n#{r.err}"
      File.read(world.dir / "got" / "-y.txt").should eq "dash\n"
    end
  end

  it "works in rsh mode (rsync -e ssm-scp), with --sudo through the fake sudo" do
    pending_if(skip)
    E2E.with_world do |world|
      File.write(world.dir / "s.txt", "secret\n")
      Dir.mkdir(world.dir / "got")
      env = world.env
      proc = Process.new("rsync", ["-e", "#{E2E.binary} --sudo", "#{world.id}:#{world.dir}/s.txt", (world.dir / "got").to_s],
        env: env, clear_env: true, chdir: world.local.to_s,
        input: Process::Redirect::Close, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
      err = proc.error.gets_to_end
      proc.output.gets_to_end
      proc.wait.exit_code.should eq(0), "stderr:\n#{err}"
      File.read(world.dir / "got" / "s.txt").should eq "secret\n"
      err.should contain "(sudo)"
    end
  end

  it "passes no --region to aws unless one is given (flag or AWS_REGION)" do
    pending_if(skip)
    E2E.with_world do |world|
      File.write(world.remote / "r.txt", "x")
      r = world.run(["#{world.id}:r.txt", world.local.to_s], unset: ["AWS_REGION", "AWS_DEFAULT_REGION"])
      r.code.should eq(0), "stderr:\n#{r.err}"
      world.aws_log.should contain "start-session --target #{world.id}"
      world.aws_log.should_not contain "--region"
    end
    E2E.with_world do |world|
      File.write(world.remote / "r.txt", "x")
      r = world.run(["--region", "eu-west-1", "#{world.id}:r.txt", world.local.to_s])
      r.code.should eq(0), "stderr:\n#{r.err}"
      world.aws_log.each_line { |line| line.should contain "--region eu-west-1" if line.includes?("start-session") }
    end
    E2E.with_world do |world|
      File.write(world.remote / "r.txt", "x")
      r = world.run(["#{world.id}:r.txt", world.local.to_s], {"AWS_REGION" => "ap-south-1"})
      r.code.should eq(0), "stderr:\n#{r.err}"
      world.aws_log.should contain "--region ap-south-1"
    end
  end

  it "resolves a Name tag: caches a unique match under name::default, warns and does not cache several" do
    pending_if(skip)
    E2E.with_world do |world|
      File.write(world.remote / "n.txt", "x")
      r = world.run(["web-1:n.txt", world.local.to_s], {"FAKE_AWS_IDS" => "i-0aaa1"}, ["AWS_REGION", "AWS_DEFAULT_REGION"])
      r.code.should eq(0), "stderr:\n#{r.err}"
      cache = world.lhome / ".cache" / "scp-ssm" / "resolve.json"
      JSON.parse(File.read(cache)).as_h.keys.should eq ["web-1::default"]
      world.aws_log.should contain "ec2 describe-instances"
      world.aws_log.should contain "start-session --target i-0aaa1"
    end
    E2E.with_world do |world|
      File.write(world.remote / "n.txt", "x")
      r = world.run(["web-2:n.txt", world.local.to_s], {"FAKE_AWS_IDS" => "i-0bbb1\ti-0bbb2"})
      r.code.should eq(0), "stderr:\n#{r.err}"
      r.err.should contain "2 instances match 'web-2'"
      r.err.should contain "not cached"
      File.exists?(world.lhome / ".cache" / "scp-ssm" / "resolve.json").should be_false
      world.aws_log.should contain "start-session --target i-0bbb1"
    end
  end

  it "rejects Name tags with a comma or wildcard before calling EC2" do
    pending_if(skip)
    E2E.with_world do |world|
      {"a,b", "web-*", "web-?"}.each do |name|
        r = world.run(["#{name}:x", world.local.to_s])
        r.code.should_not eq 0 # rsync turns the rsh command's failure into its own code
        r.err.should contain "use the instance id"
      end
      world.aws_log.should_not contain "ec2"
    end
  end

  it "says so when the aws CLI is missing (rsh mode, before the EC2 lookup)" do
    pending_if(skip)
    E2E.with_world do |world|
      bare = world.dir / "bare"
      Dir.mkdir(bare)
      r = world.run(["web-1", "rsync", "--server", "."], {"PATH" => bare.to_s})
      r.code.should eq 1
      r.err.should contain "aws CLI not found"
      r.err.should contain "brew install awscli"
    end
  end

  it "keeps the PTY session alive with no-op lines and still gets the exit status of a slow command" do
    pending_if(skip)
    E2E.with_world do |world|
      script = world.dir / "slow.sh"
      File.write(script, "#!/bin/sh\ncat >/dev/null\nsleep 2\necho 'slow message' >&2\nexit 5\n", perm: 0o755)
      r = world.run([world.id, script.to_s], {"SSM_SCP_KEEPALIVE" => "0.2"})
      r.code.should eq(5), "stderr:\n#{r.err}"
      r.err.should contain "slow message"
      r.err.should_not contain "no exit status"
    end
  end

  describe "cleanup on signals" do
    # rsync sends SIGUSR1 to its rsh child on Ctrl-C or an error.
    {Signal::INT, Signal::USR1, Signal::TERM, Signal::HUP, Signal::USR2, Signal::QUIT}.each do |sig|
      it "#{sig} stops both fake aws sessions with their children and exits 128+#{sig.value}" do
        pending_if(skip)
        E2E.with_world do |world|
          proc = world.start([world.id, E2E.sleeper(world)], quick_stop, stdin: Process::Redirect::Pipe)
          begin
            E2E.wait_for_line(proc.error, "ready")
            world.pids.size.should be >= 4 # two aws, a shell and the relay
            proc.signal(sig)
            proc.wait.exit_code.should eq 128 + sig.value
            world.all_gone?(1.second).should be_true
          ensure
            proc.signal(Signal::KILL) rescue nil
            E2E.kill_sleeper(world)
          end
        end
      end
    end

    it "a second signal during the cleanup does not skip the SIGKILL pass" do
      pending_if(skip)
      E2E.with_world do |world|
        proc = world.start([world.id, E2E.sleeper(world)], quick_stop, stdin: Process::Redirect::Pipe)
        begin
          E2E.wait_for_line(proc.error, "ready")
          # The interactive fake shell ignores SIGTERM, so the cleanup has to
          # wait out its grace period and then SIGKILL.
          proc.signal(Signal::USR1)
          sleep 0.3.seconds
          proc.signal(Signal::INT)
          proc.signal(Signal::TERM)
          proc.wait.exit_code.should eq 128 + Signal::USR1.value
          world.all_gone?(1.second).should be_true
        ensure
          proc.signal(Signal::KILL) rescue nil
          E2E.kill_sleeper(world)
        end
      end
    end

    it "leaves nothing behind when the transfer fails early (error output ends on its own line)" do
      pending_if(skip)
      E2E.with_world do |world|
        r = world.run(["#{world.id}:#{world.dir}/nope", world.local.to_s])
        r.code.should_not eq 0
        r.err.should contain "checking remote shell"
        r.err.should_not match(/\.\.\.ssm-scp:/)
        world.all_gone?.should be_true
      end
    end
  end
end
