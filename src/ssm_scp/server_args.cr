module SsmScp
  # The `rsync --server ...` words rsync hands to us in rsh mode.
  #
  # rsync has already escaped these for a remote shell (it writes `\*`, `\ `
  # etc.), exactly as it does for ssh, which joins them and lets the remote
  # shell unescape.  Quoting them again would pass the backslashes through
  # literally and break `--chown`/`--usermap`/`--groupmap` and paths with
  # spaces, so they are only joined with spaces.
  struct ServerArgs
    getter args : Array(String)

    def initialize(@args : Array(String))
    end

    def escaped : String
      @args.join(" ")
    end

    def dot_index : Int32?
      @args.index(".")
    end

    # The remote rsync is the sender, i.e. this is a download.
    def download? : Bool
      !dot_index.nil? && @args.includes?("--sender")
    end

    # Source paths to pre-check: only for a download.  For an upload the
    # remote path is the destination, which may not exist yet.
    def src_paths : Array(String)
      idx = dot_index
      idx && download? ? @args[(idx + 1)..] : [] of String
    end
  end

  module Remote
    # rc 0 = accessible, 1 = permission denied (or sudo needs a password),
    # 2 = not found.  `sudo -n` fails at once instead of waiting for a
    # password on a PTY nobody can type into; LC_ALL=C keeps the 'ermission'
    # match independent of the remote locale.
    def self.check_command(paths_escaped : String, sudo : Bool, token : String) : String
      ls_cmd = sudo ? "sudo -n env LC_ALL=C ls" : "LC_ALL=C ls"
      "if #{ls_cmd} #{paths_escaped} >/dev/null 2>&1; then printf '#{token}0\\n'; " \
      "elif #{ls_cmd} #{paths_escaped} 2>&1 | grep -qE 'ermission|sudo:'; then printf '#{token}1\\n'; " \
      "else printf '#{token}2\\n'; fi\n"
    end

    # rc -1 means the sentinel never arrived (timeout).
    def self.check_failure(rc : Int32, src_paths : Array(String)) : String
      hint = case rc
             when  1 then "(permission denied — try --sudo (needs passwordless sudo on the remote), or: chmod o+x #{shell_escape(File.dirname(src_paths.first))})"
             when -1 then "(timed out waiting for the remote check)"
             else         "(file does not exist on remote)"
             end
      "cannot access remote path: #{src_paths.join(", ")} #{hint}"
    end

    # The python listener with its accept timeout (seconds) filled in.
    def self.python_listener(accept_timeout : Int32 | Float64 = LISTENER_ACCEPT_TIMEOUT) : String
      PYTHON_LISTENER_TEMPLATE.sub("ACCEPT_TIMEOUT", accept_timeout.to_s)
    end

    def self.listener_command(sudo : Bool, rsync_args_escaped : String,
                              accept_timeout : Int32 | Float64 = LISTENER_ACCEPT_TIMEOUT) : String
      sudo_prefix = sudo ? "'sudo' '-n' " : ""
      "python3 -c \"#{python_listener(accept_timeout)}\" #{sudo_prefix}#{rsync_args_escaped} 2>/dev/null &\n"
    end

    # One round trip: quiet the shell, then check for rsync and python3.
    # Prints the token followed by rc: 0 ok, 1 rsync missing, 2 python3 missing.
    # The rc is added by printf so the echoed command line never contains
    # token+digit (echo cannot fake success).
    def self.preflight_command(token : String) : String
      "stty -echo; export PS1=''; set +o history; " \
      "bind 'set enable-bracketed-paste off' 2>/dev/null; " \
      "rc=0; command -v rsync >/dev/null 2>&1 || rc=1; " \
      "if [ \"$rc\" = 0 ]; then command -v python3 >/dev/null 2>&1 || rc=2; fi; " \
      "printf '%s%s\\n' '#{token}' \"$rc\"\n"
    end
  end
end
