{% if flag?(:darwin) %}
  lib LibProc
    # Returns the NUMBER OF PIDS written to the buffer (not bytes); `size` is
    # the buffer size in bytes.  0 means no children or an error.
    fun proc_listchildpids(ppid : LibC::Int, buffer : Void*, size : LibC::Int) : LibC::Int
  end
{% end %}

module SsmScp
  # Finds and stops a process together with everything it started.  Needed
  # because `aws ssm start-session` runs `session-manager-plugin` as a child,
  # and signalling only `aws` leaves the plugin behind.
  module ProcTree
    # Direct children of `pid` (empty if none or `pid` is gone).
    def self.child_pids(pid : Int) : Array(Int32)
      {% if flag?(:darwin) %}
        capacity = 256
        loop do
          buf = Slice(Int32).new(capacity, 0)
          n = LibProc.proc_listchildpids(pid.to_i32, buf.to_unsafe.as(Void*), (capacity * sizeof(Int32)).to_i32)
          return [] of Int32 if n <= 0
          # A full buffer may have been cut off: retry with a bigger one.
          if n >= capacity
            capacity *= 4
            next
          end
          return buf[0, n].to_a.select { |child| child > 0 }
        end
      {% else %}
        children = [] of Int32
        Dir.each_child("/proc") do |entry|
          next unless child = entry.to_i32?
          # The process may exit while we scan.
          stat = begin
            File.read("/proc/#{entry}/stat")
          rescue
            next
          end
          children << child if ppid_from_stat(stat) == pid
        end
        children
      {% end %}
    rescue
      [] of Int32
    end

    # The parent pid in the contents of a /proc/PID/stat file.  The command
    # name (field 2) is in parentheses and may itself contain spaces and
    # parentheses, so parse from the LAST ")".
    def self.ppid_from_stat(stat : String) : Int32?
      close = stat.rindex(')')
      return unless close
      fields = stat[(close + 1)..].split
      fields[1]?.try(&.to_i32?) # fields[0] is the state, fields[1] the ppid
    end

    # All descendants of `pid` (children, grandchildren, ...), deepest last.
    def self.descendants(pid : Int) : Array(Int32)
      found = [] of Int32
      queue = [pid.to_i32]
      until queue.empty?
        child_pids(queue.shift).each do |child|
          next if found.includes?(child)
          found << child
          queue << child
        end
      end
      found
    end

    # SIGTERM `pid` and all its descendants, wait up to `grace` for them to
    # go away, then SIGKILL whatever is left.  `alive` tells whether the
    # process is still there (zombies of our own children count as gone).
    def self.kill_tree(pid : Int, grace : Time::Span = 2.seconds, &alive : Int32 -> Bool) : Nil
      # Collect first: killing the parent re-parents the children.
      pids = descendants(pid) + [pid.to_i32]
      signal_all(pids, Signal::TERM)
      deadline = Time.instant + grace
      while Time.instant < deadline
        break unless pids.any? { |id| alive.call(id) }
        sleep 0.05.seconds
      end
      signal_all(pids.select { |id| alive.call(id) }, Signal::KILL)
    end

    def self.kill_tree(pid : Int, grace : Time::Span = 2.seconds) : Nil
      kill_tree(pid, grace) { |id| Process.exists?(id) }
    end

    private def self.signal_all(pids : Array(Int32), sig : Signal) : Nil
      pids.each do |id|
        Process.signal(sig, id)
      rescue
        nil
      end
    end
  end
end
