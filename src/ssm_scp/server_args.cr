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

    # Undoes rsync's backslash escaping, for showing a path to the user.
    def self.unescape(path : String) : String
      path.gsub(/\\(.)/m, "\\1")
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
    # Sends a command to the remote shell as `eval "$(printf %s BASE64 | base64 -d)"`.
    # The PTY then carries only [A-Za-z0-9+/=]: no readline completion on a
    # tab, no history expansion, no mangled control or non-ASCII bytes.  A long
    # payload is typed as several short lines (a canonical-mode tty or a
    # shell without line editing has a line length limit) collected in a
    # variable first.
    def self.wrap(command : String, limit : Int32 = PTY_CHUNK_LIMIT) : String
      b64 = Base64.strict_encode(command)
      return %(eval "$(printf %s #{b64} | base64 -d)"\n) if b64.size <= limit
      String.build do |io|
        (0...b64.size).step(limit) do |pos|
          chunk = b64[pos, limit]
          io << (pos == 0 ? "ssm_b=#{chunk}\n" : "ssm_b=${ssm_b}#{chunk}\n")
        end
        io << %(eval "$(printf %s "$ssm_b" | base64 -d)"; unset ssm_b\n)
      end
    end

    # Types `text` into the remote shell one line at a time with a short
    # pause between lines.  A shell that is busy (it has not drawn its prompt
    # yet) leaves the tty in line mode, whose input queue is small (1 KB on
    # macOS, which the specs use): several lines sent in one burst could then
    # be dropped.
    def self.send(io : IO, text : String, pause : Time::Span = 20.milliseconds) : Nil
      lines = text.lines(chomp: false)
      lines.each_with_index do |line, index|
        io.print(line)
        sleep pause if index < lines.size - 1
      end
    end

    # Checks every source path on the remote.  Output: one line
    # `<token>F<code> <path>` per failing path, then `<token><rc>` and a
    # newline.  Codes: 0 = accessible, 1 = permission denied, 2 = not found,
    # 3 = sudo needs a password.  Priority for the overall rc: 3, 1, 2.
    # LC_ALL=C keeps the 'ermission' match independent of the remote locale.
    #
    # Without sudo each path is tested with `[ -e ]`/`[ -r ]`: `ls` succeeds
    # for a file that exists but cannot be read.  The paths stay unquoted in
    # the `for` list so globs and rsync's backslash escapes work; inside the
    # loop "$f" is one concrete name.  A path that fails `-e` may be missing or
    # sit in an unsearchable directory, so `ls -d --` tells the two apart.
    # With sudo, `sudo -n` fails at once instead of waiting for a password on
    # a PTY nobody can type into; the text of the failed `ls -d --` (or of
    # sudo itself) tells the cases apart.
    # Every rc is printed by printf from separate words, so the echoed
    # command line never contains token+digit (echo cannot fake success).
    def self.check_command(paths_escaped : String, sudo : Bool, token : String) : String
      probe = if sudo
                "o=$(sudo -n env LC_ALL=C ls -d -- \"$f\" 2>&1); c=$?; " \
                "if [ \"$c\" != 0 ]; then case \"$o\" in " \
                "*ls:*ermission*) c=1;; *ls:*) c=2;; *sudo:*) c=3;; *ermission*) c=1;; *) c=2;; esac; fi; "
              else
                "c=0; if [ -e \"$f\" ]; then [ -r \"$f\" ] || c=1; " \
                "elif LC_ALL=C ls -d -- \"$f\" 2>&1 | grep -q 'ermission'; then c=1; else c=2; fi; "
              end
      "rc=0; for f in #{paths_escaped}; do #{probe}" \
      "if [ \"$c\" != 0 ]; then printf '%s%s %s\\n' '#{token}F' \"$c\" \"$f\"; " \
      "case $c in 3) rc=3;; 1) [ \"$rc\" = 3 ] || rc=1;; 2) [ \"$rc\" != 0 ] || rc=2;; esac; fi; done; " \
      "printf '%s%s\\n' '#{token}' \"$rc\"\n"
    end

    # rc -1 means the sentinel never arrived (timeout).  `failed` are the
    # paths the remote reported for this rc (already unescaped); without them
    # the paths rsync gave us are shown, with its backslash escapes undone.
    def self.check_failure(rc : Int32, src_paths : Array(String), sudo : Bool = false,
                           failed : Array(String) = [] of String) : String
      paths = failed.empty? ? src_paths.map { |path| ServerArgs.unescape(path) } : failed
      hint = case rc
             when 3 then "(sudo needs a password on the remote; --sudo needs passwordless sudo, run with sudo -n)"
             when 1
               if sudo
                 "(permission denied, even with sudo)"
               else
                 "(permission denied — try --sudo (needs passwordless sudo on the remote), or make it readable: " \
                 "chmod o+r #{shell_escape(paths.first)}, chmod o+x #{shell_escape(File.dirname(paths.first))})"
               end
             when -1 then "(timed out waiting for the remote check)"
             else         "(file does not exist on remote)"
             end
      "cannot access remote path: #{paths.join(", ")} #{hint}"
    end

    # The python listener with its accept timeout (seconds) filled in.
    #
    # Binds to a free port, prints PORT=XXXX, accepts ONE TCP connection
    # (giving up after the accept timeout, so an unused listener does not stay
    # behind) and reads the auth token from it: the client must send the exact
    # per-run bytes first, compared with hmac.compare_digest; on a mismatch
    # (or a short or slow read) rsync is NOT run and the frame below reports
    # rc 126.  Then it runs the command (rsync --server) as a CHILD in its own
    # session (via env, so a command that cannot start still yields rc 127 and
    # a message) whose stdin/stdout are the accepted socket and whose stderr
    # is a pipe.  When the child is done it writes the frame to its own stdout
    # (the PTY) as raw bytes: TOKEN+'B' line, the child's stderr, then TOKEN
    # followed by the exit code and a newline (a signal death is 128+signum).
    # argv: [1] = the frame token, [2:] = the command.  The auth token comes
    # in the environment (SSMRSH_AUTH, removed at once), not in argv, so it
    # cannot be read from `ps`.
    # The script sits in double quotes in the shell command, so it uses single
    # quotes only, and no `$`, backtick, backslash or `!`.  SIGHUP is ignored
    # from the start (inherited by the child) and the child leads its own
    # session, so neither the listener nor rsync dies with the PTY session.
    def self.python_listener(accept_timeout : Int32 | Float64 = LISTENER_ACCEPT_TIMEOUT,
                             auth_timeout : Int32 | Float64 = AUTH_TIMEOUT) : String
      [
        "import socket,os,sys,signal,subprocess,hmac",
        "signal.signal(signal.SIGHUP,signal.SIG_IGN)",
        "a=os.environ.pop('#{AUTH_ENV}','').encode()",
        "t=sys.argv[1].encode()",
        "o=sys.stdout.buffer",
        "def f(e,r):",
        " o.write(t+b'B'+bytes([10])+e+bytes([10])+t+str(r).encode()+bytes([10]))",
        " o.flush()",
        "s=socket.socket()",
        "s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)",
        "s.bind(('127.0.0.1',0))",
        "s.listen(1)",
        "o.write(b'PORT='+str(s.getsockname()[1]).encode()+bytes([10]))",
        "o.flush()",
        "s.settimeout(#{accept_timeout})",
        "c,_=s.accept()",
        "c.settimeout(#{auth_timeout})",
        "d=b''",
        "try:",
        " while len(d)<len(a):",
        "  x=c.recv(len(a)-len(d))",
        "  if not x:break",
        "  d+=x",
        "except OSError:pass",
        "if not a or not hmac.compare_digest(d,a):",
        " f(b'ssm-scp: listener auth failed, rsync not started',126)",
        " sys.exit(1)",
        "c.settimeout(None)",
        "p=subprocess.Popen(['env']+sys.argv[2:],stdin=c.fileno(),stdout=c.fileno(),stderr=subprocess.PIPE,start_new_session=True)",
        "c.close()",
        "s.close()",
        "e=p.stderr.read()",
        "r=p.wait()",
        "f(e,128-r if r<0 else r)",
      ].join("\n")
    end

    # `token` is passed to the listener as argv[1] and frames the remote
    # rsync's stderr and exit code; `auth` is the secret the client must send
    # first (see python_listener).  The listener's own stderr is dropped; the
    # rsync's stderr is relayed by it.
    def self.listener_command(sudo : Bool, rsync_args_escaped : String, token : String, auth : String,
                              accept_timeout : Int32 | Float64 = LISTENER_ACCEPT_TIMEOUT,
                              auth_timeout : Int32 | Float64 = AUTH_TIMEOUT) : String
      sudo_prefix = sudo ? "'sudo' '-n' " : ""
      "#{AUTH_ENV}=#{auth} python3 -c \"#{python_listener(accept_timeout, auth_timeout)}\" #{token} #{sudo_prefix}#{rsync_args_escaped} 2>/dev/null &\n"
    end

    # One round trip, sent as plain text (it is a fixed ASCII line, and it
    # has to run before we know that `base64` exists): quiet the shell, go to
    # $HOME like ssh does, then check for rsync, python3 and base64.  Prints
    # the token followed by rc: 0 ok, 1 rsync missing, 2 python3 missing,
    # 3 base64 missing.  Every setup step is non-fatal in dash, bash and zsh
    # (`command set` so that a special builtin's error cannot end a POSIX
    # shell).  The rc is added by printf so the echoed command line never
    # contains token+digit (echo cannot fake success).
    def self.preflight_command(token : String) : String
      "stty -echo 2>/dev/null; export PS1=''; command set +o history 2>/dev/null; " \
      "bind 'set enable-bracketed-paste off' 2>/dev/null; cd 2>/dev/null; " \
      "rc=0; command -v rsync >/dev/null 2>&1 || rc=1; " \
      "if [ \"$rc\" = 0 ]; then command -v python3 >/dev/null 2>&1 || rc=2; fi; " \
      "if [ \"$rc\" = 0 ]; then command -v base64 >/dev/null 2>&1 || rc=3; fi; " \
      "printf '%s%s\\n' '#{token}' \"$rc\"\n"
    end
  end
end
