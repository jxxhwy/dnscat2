require 'socket'

require 'log'
require 'packet'
require 'session'

# This class should be totally stateless, and rely on the Session class
# for any long-term session storage
class Dnscat2
  def Dnscat2.handle_syn(packet, session, max_packet_size)
    if(!session.syn_valid?())
      Log.log(session.id, "SYN invalid in this state")
      return nil
    end

    Log.log(session.id, "Received SYN; responding with SYN")

    session.set_their_seq(packet.seq)
    session.set_established()

    return Packet.create_syn(session.id, session.my_seq, nil)
  end

  def Dnscat2.handle_msg(packet, session, max_packet_size)
    if(!session.msg_valid?())
      Log.log("MSG invalid in this state")
      return nil
    end

    # Validate the sequence number
    if(session.their_seq != packet.seq)
      Log.log(session.id, "Bad sequence number; expected 0x%04x, got 0x%04x" % [session.their_seq, packet.seq])
      # TODO: Re-ACK what we've received?
      return
    end

    # Acknowledge the data that has been received so far
    session.ack_outgoing(packet.ack)

    # Write the incoming data to the session
    session.queue_incoming(packet.data)

    # Increment the expected sequence number
    session.increment_their_seq(packet.data.length)

    # Get any data we have queued
    data = session.read_outgoing(max_packet_size - Packet.msg_header_size)

    Log.log(session.id, "Received MSG with #{packet.data.length} bytes; responding with our own message (#{data.length} bytes)")
    Log.log(session.id, ">> \"#{packet.data}\"")
    Log.log(session.id, "<< \"#{data}\"")

    # Build the new packet
    return Packet.create_msg(session.id,
                             session.my_seq,
                             session.their_seq,
                             data)
  end

  def Dnscat2.handle_fin(packet, session, max_packet_size)
    Log.log(session.id, "Received a FIN, don't know how to handle it")
    raise(IOError, "Not implemented")
  end

  def Dnscat2.go(s)
    if(s.max_packet_size < 16)
      raise(Exception, "max_packet_size is too small")
    end

    session_id = nil
    begin
      loop do
        packet = Packet.parse(s.recv())
        session = Session.find(packet.session_id)

        response = nil
        if(packet.type == Packet::MESSAGE_TYPE_SYN)
          response = handle_syn(packet, session, s.max_packet_size)
        elsif(packet.type == Packet::MESSAGE_TYPE_MSG)
          response = handle_msg(packet, session, s.max_packet_size)
        elsif(packet.type == Packet::MESSAGE_TYPE_FIN)
          response = handle_fin(packet, session, s.max_packet_size)
        else
          raise(IOError, "Unknown packet type: #{packet.type}")
        end

        if(response)
          if(response.length > s.max_packet_size)
            raise(IOError, "Tried to send packet longer than max_packet_length")
          end
          s.send(response)
        end
      end
    rescue IOError => e
      if(!session_id.nil?)
        # TODO Send a FIN if we can
        Session.destroy(session_id)
      end

      puts(e.inspect)
      puts(e.backtrace)
    end

    s.close()
  end
end
