def new_token : String
  "#{SENTINEL_PFX}#{Random::Secure.hex(12)}"
end

# Invalid UTF-8 (remote output is arbitrary bytes) would make Regex raise,
# so scrub before matching.
def strip_ansi(s : String) : String
  s.scrub.gsub(ANSI_RE, "").gsub("\r\n", "\n").gsub("\r", "\n")
end

def shell_escape(s : String) : String
  return "~" if s == "~"
  s.starts_with?("~/") ? "~/" + shell_escape(s[2..]) : "'" + s.gsub("'", "'\\''") + "'"
end

# True if `rsync --version` output indicates rsync >= 3.2.0 (zstd support).
def rsync_zstd_capable?(version_output : String) : Bool
  return false unless m = version_output.match(/rsync\s+version\s+(\d+)\.(\d+)/)
  major, minor = m[1].to_i, m[2].to_i
  major > 3 || (major == 3 && minor >= 2)
end
