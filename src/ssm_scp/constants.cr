SENTINEL_PFX            = "SSMRSH"
CONNECT_TIMEOUT         = 30.0
SETUP_TIMEOUT           = 15.0
PORT_TIMEOUT            = 15.0 # wait for Python to print PORT=
LISTENER_ACCEPT_TIMEOUT =   60 # seconds the remote listener waits for the tunnel connection
FWD_TIMEOUT             = 20.0 # wait for port-forward tunnel to be ready
RESULT_TIMEOUT          = 10.0 # wait for the remote rsync exit status after the transfer
ANSI_RE                 = /\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/
PROMPT_RE               = /[#$]\s*$/
RESOLVE_CACHE_PATH      = Path.home / ".cache" / "scp-ssm" / "resolve.json"
RESOLVE_CACHE_TTL       = 12.hours
# As in rsync: a slash before the first colon means a local path.
REMOTE_RE = /^([^:\/]+):(.*)$/

# File extensions that are already compressed — rsync should not attempt to
# compress them further.  Covers rsync's own built-in defaults plus modern
# formats (zst, lz4, webp, heic/heif, opus, etc.).
SKIP_COMPRESS = "7z:ace:avi:bz2:deb:dll:dylib:exe:flac:gif:gz:heic:heif:iso:" \
                "jpeg:jpg:lz:lz4:lzma:lzo:m4a:m4v:mkv:mov:mp3:mp4:mpe:mpeg:mpg:" \
                "ogg:opus:png:rar:rpm:rz:so:taz:tb2:tbz:tbz2:tgz:tlz:txz:tzip:" \
                "webm:webp:wmv:xz:z:zip:zst"

# Python 3 one-liner: binds to a free port, prints PORT=XXXX, accepts one
# TCP connection (giving up after ACCEPT_TIMEOUT seconds, so an unused
# listener does not stay behind), then runs the command (rsync --server) as a
# CHILD (via env, so a command that cannot start still yields rc 127 and a
# message) whose stdin/stdout are the accepted socket and whose stderr is a pipe.
# When the child is done it writes to its own stdout (the PTY) a frame that
# ssm-scp reads back: TOKEN+'B' line, the child's stderr text, then TOKEN
# followed by the exit code and a newline (a signal death is 128+signum).
# argv: [1] = the per-run token, [2:] = the command.
# Uses only single-quoted strings so the whole script can be shell-wrapped
# in double quotes without escaping conflicts; no shell-special characters.
# SIGHUP is ignored from the very start (inherited by the child), so neither
# the listener nor rsync dies when the PTY session closes.
# ACCEPT_TIMEOUT is replaced by SsmScp::Remote.python_listener.
PYTHON_LISTENER_TEMPLATE = "import socket,os,sys,signal,subprocess;" \
                           "signal.signal(signal.SIGHUP,signal.SIG_IGN);" \
                           "s=socket.socket();" \
                           "s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);" \
                           "s.bind(('127.0.0.1',0));" \
                           "s.listen(1);" \
                           "sys.stdout.write('PORT='+str(s.getsockname()[1])+chr(10));" \
                           "sys.stdout.flush();" \
                           "s.settimeout(ACCEPT_TIMEOUT);" \
                           "c,_=s.accept();" \
                           "c.settimeout(None);" \
                           "os.set_blocking(c.fileno(),True);" \
                           "p=subprocess.Popen(['env']+sys.argv[2:],stdin=c.fileno(),stdout=c.fileno(),stderr=subprocess.PIPE);" \
                           "c.close();" \
                           "s.close();" \
                           "e=p.stderr.read().decode('utf-8','replace');" \
                           "r=p.wait();" \
                           "r=128-r if r<0 else r;" \
                           "sys.stdout.write(sys.argv[1]+'B'+chr(10)+e+chr(10)+sys.argv[1]+str(r)+chr(10));" \
                           "sys.stdout.flush()"

PYTHON_LISTENER = PYTHON_LISTENER_TEMPLATE.sub("ACCEPT_TIMEOUT", LISTENER_ACCEPT_TIMEOUT.to_s)
