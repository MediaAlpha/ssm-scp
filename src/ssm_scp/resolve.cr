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

    def self.ec2_lookup_args(name : String, region : String, profile : String?) : Array(String)
      args = ["ec2", "describe-instances",
              "--filters", "Name=tag:Name,Values=#{name}", "Name=instance-state-name,Values=running",
              "--query", "Reservations[].Instances[].InstanceId",
              "--output", "text", "--region", region]
      args += ["--profile", profile] if profile
      args
    end

    def self.parse_ids(output : String) : Array(String)
      output.split.reject(&.empty?)
    end

    # Does the argument look like HOST:PATH (rsync's remote syntax)?
    def self.remote_spec?(arg : String) : Bool
      !REMOTE_RE.match(arg).nil?
    end

    # Direct mode: exactly two positional args, at least one remote.
    def self.direct_mode?(argv : Array(String)) : Bool
      argv.size == 2 && (remote_spec?(argv[0]) || remote_spec?(argv[1]))
    end
  end
end
