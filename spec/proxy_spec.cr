require "./spec_helper"
require "socket"

describe SsmScp::Keepalive do
  it "writes the payload at the interval until stopped" do
    r, w = IO.pipe
    ka = SsmScp::Keepalive.start(w, 0.05.seconds)
    sleep 0.4.seconds
    ka.stop
    sleep 0.15.seconds
    w.close
    text = r.gets_to_end
    text.size.should be >= 3
    text.each_char(&.should(eq('\n')))
    r.close
  end

  it "writes nothing after stop" do
    r, w = IO.pipe
    ka = SsmScp::Keepalive.start(w, 0.05.seconds)
    ka.stop
    sleep 0.3.seconds
    w.close
    r.gets_to_end.size.should be <= 1
    r.close
  end

  it "stops quietly when the other end is gone" do
    r, w = IO.pipe
    r.close
    w.sync = true
    ka = SsmScp::Keepalive.start(w, 0.03.seconds)
    sleep 0.2.seconds
    ka.stop
    w.close rescue nil
  end

  it "keepalive output cannot be mistaken for a result frame" do
    SsmScp::Sentinel.result("\n\nTOKB\n\n\nTOK0\n\n", "TOK").should eq({"", 0})
    SsmScp::Sentinel.result("\n\n\n", "TOK").should be_nil
    SsmScp::Sentinel.port("\n\n").should be_nil
  end
end

describe "SsmScp.close_if_remote_stays_open" do
  it "closes the socket when the remote side does not close in time" do
    server = TCPServer.new("127.0.0.1", 0)
    client = TCPSocket.new("127.0.0.1", server.local_address.port)
    peer = server.accept
    begin
      remote_closed = Channel(Nil).new
      client.close_write
      started = Time.instant
      SsmScp.close_if_remote_stays_open(client, remote_closed, 0.3.seconds).should be_true
      (Time.instant - started).should be >= 0.25.seconds
      client.closed?.should be_true
    ensure
      peer.close
      server.close
    end
  end

  it "leaves the socket alone when the remote closes first" do
    server = TCPServer.new("127.0.0.1", 0)
    client = TCPSocket.new("127.0.0.1", server.local_address.port)
    peer = server.accept
    begin
      remote_closed = Channel(Nil).new
      spawn do
        sleep 0.1.seconds
        remote_closed.close
      end
      SsmScp.close_if_remote_stays_open(client, remote_closed, 5.seconds).should be_false
      client.closed?.should be_false
    ensure
      client.close
      peer.close
      server.close
    end
  end
end
