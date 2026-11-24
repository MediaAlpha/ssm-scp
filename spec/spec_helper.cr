require "spec"
require "file_utils"
require "../src/ssm_scp"

# Runs the block with a fresh temp directory, removed afterwards.
def with_tmp_dir(&)
  dir = File.join(Dir.tempdir, "ssm-scp-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  begin
    yield Path[dir]
  ensure
    FileUtils.rm_rf(dir)
  end
end

def parse(*args : String, region : String = "us-east-1", profile : String? = nil) : SsmScp::Options
  SsmScp::Options.parse(args.to_a, region, profile)
end

SPEC_TOKEN = "SSMRSHspec"

# Runs `argv + [cmd]` with an explicit environment and returns its stdout.
# Kills the process after `timeout` so a broken snippet cannot hang the suite.
def run_snippet(cmd : String, path : String, argv : Array(String) = ["/bin/sh", "-c"],
                timeout : Time::Span = 5.seconds) : String
  buf = IO::Memory.new
  proc = Process.new(argv[0], argv[1..] + [cmd], env: {"PATH" => path, "LC_ALL" => "C"},
    clear_env: true, input: Process::Redirect::Close, output: Process::Redirect::Pipe,
    error: Process::Redirect::Close)
  done = Channel(Nil).new
  spawn do
    IO.copy(proc.output, buf)
    proc.wait
    done.send(nil)
  end
  select
  when done.receive
  when timeout(timeout)
    proc.terminate rescue nil
    raise "snippet timed out: #{cmd}"
  end
  buf.to_s
end

def snippet_rc(cmd : String, path : String, argv : Array(String) = ["/bin/sh", "-c"]) : Int32?
  SsmScp::Sentinel.scan(run_snippet(cmd, path, argv).to_slice, SPEC_TOKEN)
end

# Writes an executable shell script.
def write_script(path : Path | String, body : String) : Nil
  File.write(path, "#!/bin/sh\n#{body}\n", perm: 0o755)
end
