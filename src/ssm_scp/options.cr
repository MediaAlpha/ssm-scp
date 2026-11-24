module SsmScp
  # Parsed command-line options (everything before the first positional arg).
  class Options
    enum Action
      Run
      Version
      Help
    end

    # nil = let the aws CLI choose (AWS_REGION, AWS_DEFAULT_REGION, the profile's config).
    property region : String?
    property profile : String?
    property? sudo = false
    property compress_level = 6
    property chown : String?
    property chmod : String?
    property rsync_args = [] of String
    property? verbose = false
    property action = Action::Run
    # Positional args left after the options (with a leading `--` removed).
    property rest = [] of String
    # Options we do not know (kept, not silently dropped).
    property unknown = [] of String

    def initialize(@region : String? = nil, @profile : String? = nil)
    end

    # From the environment only; nil when unset, so that the aws CLI can fall
    # back on the region of the selected profile.
    def self.default_region : String?
      {"AWS_REGION", "AWS_DEFAULT_REGION"}.each do |name|
        if (val = ENV[name]?) && !val.empty?
          return val
        end
      end
      nil
    end

    def self.parse(args : Array(String), region : String? = default_region,
                   profile : String? = ENV["AWS_PROFILE"]?) : Options
      opts = new(region, profile)
      argv = args.dup

      while (f = argv.first?) && f.starts_with?("-") && f != "--"
        flag = argv.shift
        case flag
        when "-V", "--version"
          opts.action = Action::Version
          return opts
        when "-h", "--help"
          opts.action = Action::Help
          return opts
        else
          apply(opts, flag, argv)
        end
      end

      argv.shift if argv.first? == "--"
      opts.rest = argv
      opts
    end

    VALUED_FLAGS = {"--region", "--profile", "--chown", "--chmod", "--rsync-arg", "--compress-level"}

    # `--opt=value` is split here so every valued option accepts both forms.
    private def self.apply(opts : Options, flag : String, argv : Array(String)) : Nil
      if flag.starts_with?("--") && (eq = flag.index('=')) && VALUED_FLAGS.includes?(flag[0, eq])
        apply_valued(opts, flag[0, eq], flag[(eq + 1)..], argv)
        return
      end
      case flag
      when "--sudo"           then opts.sudo = true
      when "-v", "--verbose"  then opts.verbose = true
      when "-l"               then argv.shift?
      when .in?(VALUED_FLAGS) then apply_valued(opts, flag, nil, argv)
      else                         opts.unknown << flag
      end
    end

    # Options that take a value, given inline (--opt=value) or as the next word.
    private def self.apply_valued(opts : Options, flag : String, inline : String?, argv : Array(String)) : Nil
      val = inline || value(argv, flag)
      case flag
      when "--region"         then opts.region = val
      when "--profile"        then opts.profile = val
      when "--chown"          then opts.chown = val
      when "--chmod"          then opts.chmod = val
      when "--rsync-arg"      then opts.rsync_args << val
      when "--compress-level" then opts.compress_level = level(val)
      end
    end

    private def self.value(argv : Array(String), flag : String) : String
      argv.shift? || raise Error.new("missing value for #{flag}")
    end

    private def self.level(text : String) : Int32
      n = text.to_i?
      raise Error.new("--compress-level must be 1–22") unless n && n.in?(1..22)
      n
    end

    def self.help_lines : Array(String)
      [
        "Usage: ssm-scp [options] HOST:PATH... LOCAL",
        "       ssm-scp [options] LOCAL... HOST:PATH",
        "  HOST is an instance id (i-0abc...) or an EC2 Name tag.",
        "",
        "Options:",
        "  --region R          AWS region (default: AWS_REGION, AWS_DEFAULT_REGION, else the profile's region)",
        "  --profile P         AWS CLI profile (default: AWS_PROFILE)",
        "  --sudo              run remote rsync via sudo (needed for files owned by other users)",
        "  --chown USER:GROUP  set owner/group of transferred files (rsync --chown; needs --sudo)",
        "  --chmod MODE        set mode of transferred files (rsync --chmod, e.g. 0440 or F440)",
        "  --rsync-arg ARG     pass ARG to rsync (repeatable), e.g. --rsync-arg --dry-run",
        "  --compress-level N  zstd/zlib compression level 1–22 (default: 6)",
        "  -v, --verbose       verbose output",
        "  -V, --version       print the version and exit",
        "  -h, --help          print this help and exit",
        "  (--region=R, --profile=P, --chown=X, --chmod=X, --rsync-arg=X, --compress-level=N also work)",
      ]
    end

    # The command string handed to `rsync -e`.  rsync splits it on spaces and
    # honours single and double quotes (no backslashes); inside quotes a
    # doubled quote is a literal one.  A part with whitespace or a quote is
    # therefore single-quoted, with ' written as ''.
    def rsh_command(exe : String) : String
      parts = [exe]
      if reg = @region
        parts += ["--region", reg]
      end
      if prof = @profile
        parts += ["--profile", prof]
      end
      parts << "--sudo" if sudo?
      parts << "--compress-level=#{@compress_level}"
      parts << "-v" if verbose?
      parts.map { |part| self.class.rsh_quote(part) }.join(" ")
    end

    def self.rsh_quote(part : String) : String
      part.matches?(/[\s'"]/) ? "'" + part.gsub("'", "''") + "'" : part
    end

    # Flags for the local rsync in direct mode, in order.
    def rsync_flags(local_modern : Bool) : Array(String)
      flags = ["--progress", "-h", "-z", "--compress-level=#{@compress_level}"]
      flags << "--skip-compress=#{SKIP_COMPRESS}" if local_modern
      flags << "-v" if verbose?
      if (own = @chown) && !sudo?
        raise Error.new("--chown needs --sudo (only root can change ownership on the remote)")
      end
      flags << "--chown=#{own}" if own
      flags << "--chmod=#{@chmod}" if @chmod
      flags.concat(@rsync_args)
      flags
    end

    # Full argument list for `rsync` in direct mode.  The positional args come
    # after `--`, so a file called `-x.txt` is not taken for an option.
    def rsync_argv(exe : String, local_modern : Bool, positional : Array(String)) : Array(String)
      ["-e", rsh_command(exe)] + rsync_flags(local_modern) + ["--"] + positional
    end
  end
end
