SENTINEL_PFX            = "SSMRSH"
CONNECT_TIMEOUT         = 30.0
SETUP_TIMEOUT           = 15.0
PORT_TIMEOUT            = 15.0 # wait for Python to print PORT=
LISTENER_ACCEPT_TIMEOUT =   60 # seconds the remote listener waits for the tunnel connection
FWD_TIMEOUT             = 20.0 # wait for port-forward tunnel to be ready
RESULT_TIMEOUT          = 10.0 # wait for the remote rsync exit status after the transfer
HALF_CLOSE_TIMEOUT      = 30.0 # after local EOF, wait this long for the remote side to close
KEEPALIVE_INTERVAL      = 60.0 # seconds between no-op newlines on the PTY session during a transfer
AUTH_TIMEOUT            =   10 # seconds the listener waits for the auth token after accept
AUTH_ENV                = "SSMRSH_AUTH"
PTY_CHUNK_LIMIT         = 400 # max base64 chars per line typed into the PTY
# CSI sequences, and OSC sequences (window titles etc.) ended by BEL or ESC \.
ANSI_RE            = /\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/
PROMPT_RE          = /[#$%>]\s*\z/
RESOLVE_CACHE_PATH = Path.home / ".cache" / "scp-ssm" / "resolve.json"
RESOLVE_CACHE_TTL  = 12.hours
# As in rsync: a slash before the first colon means a local path.
REMOTE_RE = /^([^:\/]+):(.*)$/

# File extensions that are already compressed — rsync should not attempt to
# compress them further.  Covers rsync's own built-in defaults plus modern
# formats (zst, lz4, webp, heic/heif, opus, etc.).
SKIP_COMPRESS = "7z:ace:avi:bz2:deb:dll:dylib:exe:flac:gif:gz:heic:heif:iso:" \
                "jpeg:jpg:lz:lz4:lzma:lzo:m4a:m4v:mkv:mov:mp3:mp4:mpe:mpeg:mpg:" \
                "ogg:opus:png:rar:rpm:rz:so:taz:tb2:tbz:tbz2:tgz:tlz:txz:tzip:" \
                "webm:webp:wmv:xz:z:zip:zst"
