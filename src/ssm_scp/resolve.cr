module SsmScp
  module Resolve
    INSTANCE_ID_RE = /^i-[0-9a-f]+$/

    def self.instance_id?(name : String) : Bool
      name.matches?(INSTANCE_ID_RE)
    end

    # `rsync` passes `user@host`; only the part after the last-split `@` is the target.
    def self.host_from_arg(host_arg : String) : String
      host_arg.includes?("@") ? host_arg.split("@", 2).last : host_arg
    end

    # The EC2 filter takes `,` as a value separator and `*`/`?` as wildcards,
    # so such names would match other instances than the one asked for.
    def self.check_name!(name : String) : Nil
      if bad = name.chars.find(&.in?(',', '*', '?'))
        raise Error.new("instance name '#{name}' contains '#{bad}', which EC2 filters treat as a list separator or wildcard; use the instance id")
      end
    end

    def self.ec2_lookup_args(name : String, region : String?, profile : String?) : Array(String)
      args = ["ec2", "describe-instances",
              "--filters", "Name=tag:Name,Values=#{name}", "Name=instance-state-name,Values=running",
              "--query", "Reservations[].Instances[].InstanceId",
              "--output", "text"]
      args + aws_common_args(region, profile)
    end

    # `--region` and `--profile` for an aws command; each only when set, so
    # that the aws CLI's own defaults (environment, config file) apply.
    def self.aws_common_args(region : String?, profile : String?) : Array(String)
      args = [] of String
      args += ["--region", region] if region
      args += ["--profile", profile] if profile
      args
    end

    # `aws ssm start-session` arguments for the PTY (shell) session.
    def self.session_args(target : String, region : String?, profile : String?) : Array(String)
      ["ssm", "start-session", "--target", target] + aws_common_args(region, profile)
    end

    # ... and for the port-forwarding session to the remote listener.
    def self.forward_args(target : String, local_port : Int, remote_port : Int,
                          region : String?, profile : String?) : Array(String)
      params = %({"portNumber":["#{remote_port}"],"localPortNumber":["#{local_port}"]})
      ["ssm", "start-session", "--target", target, "--document-name", "AWS-StartPortForwardingSession",
       "--parameters", params] + aws_common_args(region, profile)
    end

    def self.parse_ids(output : String) : Array(String)
      output.split.reject(&.empty?)
    end

    # Does the argument look like HOST:PATH (rsync's remote syntax)?
    def self.remote_spec?(arg : String) : Bool
      !REMOTE_RE.match(arg).nil?
    end

    # Direct mode: two or more positional args, at least one remote.  rsync
    # calls us in rsh mode as `ssm-scp HOST rsync --server ...`, so a
    # `--server` word means rsh mode.
    def self.direct_mode?(argv : Array(String)) : Bool
      argv.size >= 2 && !argv.includes?("--server") && argv.any? { |arg| remote_spec?(arg) }
    end
  end
end
