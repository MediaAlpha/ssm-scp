SENTINEL_PFX            = "SSMRSH"
CONNECT_TIMEOUT         = 30.0
SETUP_TIMEOUT           = 15.0
PORT_TIMEOUT            = 15.0 # wait for Python to print PORT=
LISTENER_ACCEPT_TIMEOUT =   60 # seconds the remote listener waits for the tunnel connection
FWD_TIMEOUT             = 20.0 # wait for port-forward tunnel to be ready
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
# listener does not stay behind), dup2's it onto fd 0/1, then execvp's
# rsync --server.
# Uses only single-quoted strings so the whole script can be shell-wrapped
# in double quotes without escaping conflicts.
# SIGHUP is ignored from the very start (inherited across execvp), so neither
# the listener nor rsync dies when the PTY session closes.
# ACCEPT_TIMEOUT is replaced by SsmScp::Remote.python_listener.
PYTHON_LISTENER_TEMPLATE = "import socket,os,sys,signal;" \
                           "signal.signal(signal.SIGHUP,signal.SIG_IGN);" \
                           "s=socket.socket();" \
                           "s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);" \
                           "s.bind(('127.0.0.1',0));" \
                           "s.listen(1);" \
                           "sys.stdout.write('PORT='+str(s.getsockname()[1])+'\\n');" \
                           "sys.stdout.flush();" \
                           "s.settimeout(ACCEPT_TIMEOUT);" \
                           "c,_=s.accept();" \
                           "c.settimeout(None);" \
                           "os.set_blocking(c.fileno(),True);" \
                           "os.dup2(c.fileno(),0);" \
                           "os.dup2(c.fileno(),1);" \
                           "c.close();" \
                           "s.close();" \
                           "os.execvp(sys.argv[1],sys.argv[1:])"

PYTHON_LISTENER = PYTHON_LISTENER_TEMPLATE.sub("ACCEPT_TIMEOUT", LISTENER_ACCEPT_TIMEOUT.to_s)
