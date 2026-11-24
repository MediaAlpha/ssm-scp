module SsmScp
  # Writes a harmless newline to an IO (the PTY session) at an interval, so
  # that SSM's idle timeout cannot end the session during a long transfer.
  # The shell reads an empty command line and prints nothing but possibly a
  # blank line, which the result parser ignores.
  class Keepalive
    def initialize(@io : IO, @interval : Time::Span, @payload : String = "\n")
      @stop = Channel(Nil).new
    end

    def self.start(io : IO, interval : Time::Span, payload : String = "\n") : Keepalive
      new(io, interval, payload).tap(&.start)
    end

    def start : Nil
      spawn do
        loop do
          select
          when @stop.receive?
            break
          when timeout(@interval)
            begin
              @io.print(@payload)
            rescue
              break
            end
          end
        end
      end
    end

    def stop : Nil
      @stop.close unless @stop.closed?
    end
  end

  # After our side of the proxy hit EOF (we half-closed the socket), the remote
  # side should close too.  If `remote_closed` (closed by the reader when it
  # sees EOF) does not fire within `timeout`, close the socket fully so
  # nothing can hang forever.  Returns true if the socket had to be closed.
  def self.close_if_remote_stays_open(sock : IO, remote_closed : Channel(Nil), timeout : Time::Span) : Bool
    select
    when remote_closed.receive?
      false
    when timeout(timeout)
      sock.close rescue nil
      true
    end
  end
end
