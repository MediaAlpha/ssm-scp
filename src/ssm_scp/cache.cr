module SsmScp
  # Name -> instance-id cache (JSON file, shared with scp-ssm).
  class ResolveCache
    getter path : Path
    getter ttl : Time::Span

    def initialize(@path : Path = RESOLVE_CACHE_PATH, @ttl : Time::Span = RESOLVE_CACHE_TTL)
    end

    # "name::region" (the scp-ssm format) without a profile, so that file stays
    # compatible; "name::region::profile" when an AWS profile is set, because
    # another account can have the same Name tag.
    def self.key(name : String, region : String, profile : String? = nil) : String
      profile ? "#{name}::#{region}::#{profile}" : "#{name}::#{region}"
    end

    def lookup(name : String, region : String, profile : String? = nil, now : Time = Time.utc) : String?
      return unless File.exists?(@path)
      entries = JSON.parse(File.read(@path))
      entry = entries[self.class.key(name, region, profile)]? || return
      return if expired?(entry, now)
      entry["id"].as_s
    rescue
      nil
    end

    # Also drops expired entries, so the file does not grow forever.
    def store(name : String, region : String, id : String, profile : String? = nil, now : Time = Time.utc) : Nil
      entries = load_entries
      entries.reject! { |_, entry| expired?(entry, now) }
      entries[self.class.key(name, region, profile)] = JSON.parse({"id" => id, "at" => now.to_rfc3339}.to_json)
      write_entries(entries)
    rescue
      nil
    end

    # Removes one entry (e.g. an instance id that turned out to be stale).
    def evict(name : String, region : String, profile : String? = nil) : Nil
      return unless File.exists?(@path)
      entries = load_entries
      return unless entries.delete(self.class.key(name, region, profile))
      write_entries(entries)
    rescue
      nil
    end

    private def expired?(entry : JSON::Any, now : Time) : Bool
      now - Time.parse_iso8601(entry["at"].as_s) > @ttl
    rescue
      true
    end

    private def write_entries(entries : Hash(String, JSON::Any)) : Nil
      Dir.mkdir_p(@path.parent.to_s)
      tmp = "#{@path}.tmp.#{Process.pid}"
      begin
        File.write(tmp, entries.to_json)
        File.rename(tmp, @path.to_s)
      ensure
        File.delete?(tmp)
      end
    end

    # A corrupt or unreadable cache file must not stop new entries from being
    # written (it would otherwise stay corrupt forever): start afresh.
    private def load_entries : Hash(String, JSON::Any)
      return Hash(String, JSON::Any).new unless File.exists?(@path)
      JSON.parse(File.read(@path)).as_h
    rescue
      Hash(String, JSON::Any).new
    end
  end
end
