require "./spec_helper"

describe SsmScp::ResolveCache do
  now = Time.utc(2026, 11, 24, 12, 0, 0)

  it "returns nil when the cache file does not exist" do
    with_tmp_dir do |dir|
      SsmScp::ResolveCache.new(dir / "x" / "resolve.json").lookup("web", "us-east-1").should be_nil
    end
  end

  it "stores and looks up an entry, creating missing directories" do
    with_tmp_dir do |dir|
      cache = SsmScp::ResolveCache.new(dir / "a" / "b" / "resolve.json")
      cache.store("web", "us-east-1", "i-0abc", now: now)
      cache.lookup("web", "us-east-1", now: now).should eq "i-0abc"
    end
  end

  it "keys by name and region" do
    with_tmp_dir do |dir|
      cache = SsmScp::ResolveCache.new(dir / "resolve.json")
      cache.store("web", "us-east-1", "i-1", now: now)
      cache.store("web", "us-west-2", "i-2", now: now)
      cache.lookup("web", "us-east-1", now: now).should eq "i-1"
      cache.lookup("web", "us-west-2", now: now).should eq "i-2"
      cache.lookup("web", "eu-west-1", now: now).should be_nil
      cache.lookup("db", "us-east-1", now: now).should be_nil
    end
  end

  it "keeps the scp-ssm key format name::region" do
    SsmScp::ResolveCache.key("web", "us-east-1").should eq "web::us-east-1"
  end

  it "uses the literal \"default\" without a region" do
    SsmScp::ResolveCache.key("web", nil).should eq "web::default"
    SsmScp::ResolveCache.key("web", nil, "prod").should eq "web::default::prod"
  end

  it "stores and looks up an entry without a region, apart from a regional one" do
    with_tmp_dir do |dir|
      cache = SsmScp::ResolveCache.new(dir / "resolve.json")
      cache.store("web", nil, "i-d", now: now)
      cache.store("web", "us-east-1", "i-r", now: now)
      cache.lookup("web", nil, now: now).should eq "i-d"
      cache.lookup("web", "us-east-1", now: now).should eq "i-r"
      cache.evict("web", nil)
      cache.lookup("web", nil, now: now).should be_nil
      cache.lookup("web", "us-east-1", now: now).should eq "i-r"
    end
  end

  it "includes the AWS profile in the key when one is set" do
    SsmScp::ResolveCache.key("web", "us-east-1", "prod").should eq "web::us-east-1::prod"
    SsmScp::ResolveCache.key("web", "us-east-1", nil).should eq "web::us-east-1"
  end

  it "keeps the same Name tag in two accounts (profiles) apart" do
    with_tmp_dir do |dir|
      cache = SsmScp::ResolveCache.new(dir / "resolve.json")
      cache.store("web-1", "us-east-1", "i-aaa", "prod", now: now)
      cache.store("web-1", "us-east-1", "i-bbb", "dev", now: now)
      cache.store("web-1", "us-east-1", "i-ccc", now: now)
      cache.lookup("web-1", "us-east-1", "prod", now: now).should eq "i-aaa"
      cache.lookup("web-1", "us-east-1", "dev", now: now).should eq "i-bbb"
      cache.lookup("web-1", "us-east-1", now: now).should eq "i-ccc"
      cache.lookup("web-1", "us-east-1", "other", now: now).should be_nil
    end
  end

  describe "#evict" do
    it "removes only the named entry" do
      with_tmp_dir do |dir|
        cache = SsmScp::ResolveCache.new(dir / "resolve.json")
        cache.store("a", "r", "i-1", "p", now: now)
        cache.store("a", "r", "i-2", now: now)
        cache.store("b", "r", "i-3", "p", now: now)
        cache.evict("a", "r", "p")
        cache.lookup("a", "r", "p", now: now).should be_nil
        cache.lookup("a", "r", now: now).should eq "i-2"
        cache.lookup("b", "r", "p", now: now).should eq "i-3"
      end
    end

    it "is harmless for a missing entry, missing file or corrupt file" do
      with_tmp_dir do |dir|
        path = dir / "resolve.json"
        cache = SsmScp::ResolveCache.new(path)
        cache.evict("a", "r")
        File.exists?(path).should be_false
        cache.store("b", "r", "i-1", now: now)
        cache.evict("a", "r")
        cache.lookup("b", "r", now: now).should eq "i-1"
        File.write(path, "{corrupt")
        cache.evict("b", "r")
      end
    end
  end

  it "prunes expired entries when storing" do
    with_tmp_dir do |dir|
      path = dir / "resolve.json"
      cache = SsmScp::ResolveCache.new(path, 1.hour)
      cache.store("old", "r", "i-old", now: now)
      cache.store("fresh", "r", "i-new", now: now + 5.hours)
      JSON.parse(File.read(path)).as_h.keys.should eq ["fresh::r"]
    end
  end

  it "overwrites an existing entry and keeps the others" do
    with_tmp_dir do |dir|
      cache = SsmScp::ResolveCache.new(dir / "resolve.json")
      cache.store("a", "r", "i-1", now: now)
      cache.store("b", "r", "i-2", now: now)
      cache.store("a", "r", "i-3", now: now)
      cache.lookup("a", "r", now: now).should eq "i-3"
      cache.lookup("b", "r", now: now).should eq "i-2"
    end
  end

  describe "TTL" do
    it "is valid just before and at the TTL boundary" do
      with_tmp_dir do |dir|
        cache = SsmScp::ResolveCache.new(dir / "resolve.json", 12.hours)
        cache.store("web", "r", "i-1", now: now)
        cache.lookup("web", "r", now: now + 11.hours + 59.minutes).should eq "i-1"
        cache.lookup("web", "r", now: now + 12.hours).should eq "i-1"
      end
    end

    it "expires after the TTL" do
      with_tmp_dir do |dir|
        cache = SsmScp::ResolveCache.new(dir / "resolve.json", 12.hours)
        cache.store("web", "r", "i-1", now: now)
        cache.lookup("web", "r", now: now + 12.hours + 1.second).should be_nil
        cache.lookup("web", "r", now: now + 2.days).should be_nil
      end
    end

    it "honours a custom TTL" do
      with_tmp_dir do |dir|
        cache = SsmScp::ResolveCache.new(dir / "resolve.json", 1.minute)
        cache.store("web", "r", "i-1", now: now)
        cache.lookup("web", "r", now: now + 30.seconds).should eq "i-1"
        cache.lookup("web", "r", now: now + 2.minutes).should be_nil
      end
    end

    it "defaults to 12 hours" do
      SsmScp::ResolveCache.new.ttl.should eq 12.hours
      RESOLVE_CACHE_TTL.should eq 12.hours
    end

    it "an expired entry is refreshed by store" do
      with_tmp_dir do |dir|
        cache = SsmScp::ResolveCache.new(dir / "resolve.json", 1.hour)
        cache.store("web", "r", "i-old", now: now)
        cache.store("web", "r", "i-new", now: now + 5.hours)
        cache.lookup("web", "r", now: now + 5.hours).should eq "i-new"
      end
    end
  end

  describe "bad cache files" do
    it "treats corrupt JSON as a miss" do
      with_tmp_dir do |dir|
        path = dir / "resolve.json"
        File.write(path, "{not json")
        SsmScp::ResolveCache.new(path).lookup("web", "r", now: now).should be_nil
      end
    end

    it "treats an empty file, a JSON array and a JSON null as a miss" do
      with_tmp_dir do |dir|
        path = dir / "resolve.json"
        {"", "[]", "null", "42", "\"s\""}.each do |content|
          File.write(path, content)
          SsmScp::ResolveCache.new(path).lookup("web", "r", now: now).should be_nil
        end
      end
    end

    it "treats entries with missing or wrong-typed fields as a miss" do
      with_tmp_dir do |dir|
        path = dir / "resolve.json"
        {
          %({"web::r": {}}),
          %({"web::r": {"id": "i-1"}}),
          %({"web::r": {"at": "2026-11-24T12:00:00Z"}}),
          %({"web::r": {"id": 5, "at": "2026-11-24T12:00:00Z"}}),
          %({"web::r": {"id": "i-1", "at": "not a date"}}),
          %({"web::r": "i-1"}),
        }.each do |content|
          File.write(path, content)
          SsmScp::ResolveCache.new(path).lookup("web", "r", now: now).should be_nil
        end
      end
    end

    it "recovers: store replaces a corrupt file" do
      with_tmp_dir do |dir|
        path = dir / "resolve.json"
        File.write(path, "{corrupt")
        cache = SsmScp::ResolveCache.new(path)
        cache.store("web", "r", "i-1", now: now)
        cache.lookup("web", "r", now: now).should eq "i-1"
      end
    end

    it "recovers when the file holds valid JSON that is not an object" do
      with_tmp_dir do |dir|
        path = dir / "resolve.json"
        File.write(path, "[1,2]")
        cache = SsmScp::ResolveCache.new(path)
        cache.store("web", "r", "i-1", now: now)
        cache.lookup("web", "r", now: now).should eq "i-1"
      end
    end

    it "store never raises when the location is unwritable" do
      with_tmp_dir do |dir|
        blocker = dir / "file"
        File.write(blocker, "x")
        cache = SsmScp::ResolveCache.new(blocker / "sub" / "resolve.json")
        cache.store("web", "r", "i-1", now: now)
        cache.lookup("web", "r", now: now).should be_nil
      end
    end

    it "leaves no temp files behind" do
      with_tmp_dir do |dir|
        cache = SsmScp::ResolveCache.new(dir / "resolve.json")
        cache.store("web", "r", "i-1", now: now)
        Dir.children(dir.to_s).should eq ["resolve.json"]
      end
    end

    it "does not touch other entries' JSON shape" do
      with_tmp_dir do |dir|
        path = dir / "resolve.json"
        cache = SsmScp::ResolveCache.new(path)
        cache.store("web", "r", "i-1", now: now)
        json = JSON.parse(File.read(path))
        json["web::r"]["id"].as_s.should eq "i-1"
        Time.parse_iso8601(json["web::r"]["at"].as_s).should eq now
      end
    end
  end
end
