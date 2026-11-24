require "./spec_helper"

describe SsmScp::ProcTree do
  describe ".ppid_from_stat" do
    it "reads the parent pid after the command name" do
      SsmScp::ProcTree.ppid_from_stat("1234 (bash) S 567 1234 1234 0 -1").should eq 567
    end

    it "copes with spaces and parentheses in the command name" do
      SsmScp::ProcTree.ppid_from_stat("42 (a) b (c) S 7 42 42 0 -1").should eq 7
    end

    it "returns nil for garbage" do
      SsmScp::ProcTree.ppid_from_stat("nothing").should be_nil
      SsmScp::ProcTree.ppid_from_stat("1 (x)").should be_nil
    end
  end

  it "lists the children of a process and kills the whole tree" do
    shell = Process.new("/bin/sh", ["-c", "sleep 30 & sleep 30 & wait"],
      input: Process::Redirect::Close, output: Process::Redirect::Close, error: Process::Redirect::Close)
    kids = [] of Int32
    begin
      # Give the shell a moment to start both sleeps.
      50.times do
        kids = SsmScp::ProcTree.child_pids(shell.pid)
        break if kids.size >= 2
        sleep 0.1.seconds
      end
      kids.size.should eq 2
      SsmScp::ProcTree.descendants(shell.pid).sort!.should eq kids.sort

      SsmScp::ProcTree.kill_tree(shell.pid) { |pid| pid == shell.pid ? shell.exists? : Process.exists?(pid) }
      shell.wait
      sleep 0.2.seconds # kids are re-parented to init, which reaps them
      SsmScp::ProcTree.child_pids(shell.pid).should be_empty
      kids.each { |pid| Process.exists?(pid).should be_false }
    ensure
      kids.each { |pid| Process.signal(Signal::KILL, pid) rescue nil }
      shell.terminate rescue nil
    end
  end

  it "SIGKILLs a process that ignores SIGTERM" do
    shell = Process.new("/bin/sh", ["-c", "trap '' TERM; sleep 30 & wait"],
      input: Process::Redirect::Close, output: Process::Redirect::Close, error: Process::Redirect::Close)
    begin
      50.times do
        break if SsmScp::ProcTree.child_pids(shell.pid).size >= 1
        sleep 0.1.seconds
      end
      kids = SsmScp::ProcTree.child_pids(shell.pid)
      kids.size.should eq 1
      started = Time.instant
      SsmScp::ProcTree.kill_tree(shell.pid, 0.5.seconds) { |pid| pid == shell.pid ? shell.exists? : Process.exists?(pid) }
      (Time.instant - started).should be < 3.seconds
      shell.wait
      sleep 0.2.seconds
      shell.exists?.should be_false
      Process.exists?(kids.first).should be_false
    ensure
      shell.signal(Signal::KILL) rescue nil
    end
  end

  it "returns no children for a pid that does not exist" do
    SsmScp::ProcTree.child_pids(2_000_000_000).should be_empty
  end
end
