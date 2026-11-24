require "./spec_helper"

# Each example documents what the code does today, not what it should do.
describe "known quirks" do
  it "known quirk: a typo'd flag leaves its value as a positional argument" do
    o = SsmScp::Options.parse(["--regoin", "us-west-2", "a:b", "c"], "us-east-1", nil)
    o.region.should eq "us-east-1"
    o.unknown.should eq ["--regoin"]
    o.rest.should eq ["us-west-2", "a:b", "c"]
    # Three positionals with a remote one: direct mode, rsync then rejects it.
    SsmScp::Resolve.direct_mode?(o.rest).should be_true
  end
end
