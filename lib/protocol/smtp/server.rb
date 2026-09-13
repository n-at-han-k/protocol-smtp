# frozen_string_literal: true

require_relative "connection"
require_relative "message"
require_relative "reply"

module Protocol
  module SMTP
    # The server side of an SMTP conversation: RFC 5321's command/reply state
    # machine over a stream.
    #
    #   Protocol::SMTP::Server.new(stream).each do |message|
    #     Protocol::SMTP::Reply.ok("queued")
    #   end
    #
    # The block is called with each complete message and answers with the
    # Reply the client is given. What a framework lets its users return
    # instead — a String, a status code, nothing at all — is that framework's
    # business, not the protocol's.
    class Server < Connection
      DEFAULT_MAXIMUM_MESSAGE_SIZE = 20 * 1024 * 1024

      # @parameter stream [IO | IO::Stream::Buffered | StringIO] The stream to talk over.
      # @parameter domain [String] The domain this server announces itself as.
      # @parameter peer [String | Nil] Where the client connected from, for the message.
      # @parameter maximum_message_size [Integer] Refuse a message larger than this.
      # @parameter starttls [Proc | Nil] Given the current stream, returns an
      #   encrypted one. Advertises STARTTLS when present (RFC 3207).
      def initialize(
        stream,
        domain: "localhost",
        peer: nil,
        maximum_message_size: DEFAULT_MAXIMUM_MESSAGE_SIZE,
        starttls: nil,
        **options
      )
        super(stream, **options)

        @domain = domain
        @peer = peer
        @maximum_message_size = maximum_message_size
        @starttls = starttls
        @secure = false
        @state = :command
        @helo = nil
        @message = nil
      end

      # @attribute [String] The domain this server announces itself as.
      attr_reader :domain

      # @attribute [String | Nil] Where the client connected from.
      attr_reader :peer

      # @attribute [String | Nil] The domain the client introduced itself as.
      attr_reader :helo

      # @attribute [Message | Nil] The transaction in progress, if any.
      attr_reader :message

      # @attribute [Integer] The largest message this server will accept.
      attr_reader :maximum_message_size

      # @returns [Boolean] Whether the connection was upgraded to TLS.
      def secure? = @secure

      # Greet the client, then answer every line it sends until it quits or
      # goes away. Each complete message goes to the block, whose return value
      # is written back as the reply.
      #
      # @yields {|message| ...} Each complete message.
      #   @parameter message [Message]
      #   @returns [Reply | Nil]
      def each(&block)
        write(Reply.new(220, "#{@domain} ESMTP"))

        while !closed? && (line = read_line)
          write(receive(line, &block))
        end
      ensure
        close
      end

      private

        def write(reply)
          case reply
          when nil then nil
          else write_line(reply.to_s)
          end
        end

        def receive(line, &block)
          case @state
          when :data then collect(line, &block)
          when :discard then discard(line)
          else dispatch(line)
          end
        end

        def dispatch(line)
          line.partition(" ").then do |verb, _, rest|
            command(verb.upcase, rest.strip)
          end
        end

        # RFC 5321 4.3.2 is a table of which command may follow which; these
        # are its rows.
        def command(verb, argument)
          case [verb, argument]
          in ["EHLO", domain] then process_ehlo(domain)
          in ["HELO", domain] then process_helo(domain)
          in ["STARTTLS", _] then process_starttls
          in ["MAIL", /\AFROM:/i => arg] then mail_from(address(arg))
          in ["MAIL", _] then Reply.new(501, "Syntax: MAIL FROM:<address>")
          in ["RCPT", /\ATO:/i => arg] then rcpt_to(address(arg))
          in ["RCPT", _] then Reply.new(501, "Syntax: RCPT TO:<address>")
          in ["DATA", _] then data
          in ["RSET", _] then rset
          in ["NOOP", _] then Reply.ok
          in ["QUIT", _] then quit
          in ["AUTH" | "VRFY" | "EXPN" | "HELP", _] then Reply.new(502, "Command not implemented")
          else Reply.new(500, "Unknown command")
          end
        end

        def process_ehlo(domain)
          case domain
          when "" then Reply.new(501, "Syntax: EHLO domain")
          else
            reset(domain)
            Reply.new(250, ["#{@domain} greets #{domain}", *advertise])
          end
        end

        # SIZE (RFC 1870) so a client can give up before sending, 8BITMIME
        # (RFC 6152) because #data is bytes either way, and STARTTLS
        # (RFC 3207) only while an upgrade is actually possible.
        def advertise
          ["SIZE #{@maximum_message_size}", "8BITMIME"].tap do |extensions|
            case !@secure && !@starttls.nil?
            when true then extensions << "STARTTLS"
            end
          end
        end

        def process_helo(domain)
          case domain
          when "" then Reply.new(501, "Syntax: HELO domain")
          else
            reset(domain)
            Reply.new(250, @domain)
          end
        end

        # RFC 3207 4.2: the 220 goes out in the clear, the handshake happens
        # over the bare stream, and everything the client said before it is
        # forgotten — it has to EHLO again.
        def process_starttls
          case @starttls
          when nil then Reply.new(454, "TLS not available")
          else
            write(Reply.new(220, "Ready to start TLS"))
            @stream = @starttls.call(@stream)
            @secure = true
            reset(nil)
            nil
          end
        end

        # RFC 5321 4.1.1.2: MAIL FROM begins a transaction and clears the
        # buffers, so a second one mid-transaction replaces the first rather
        # than erroring — which is what a client that retries expects.
        def mail_from(from)
          case @helo
          when nil then Reply.new(503, "HELO/EHLO first")
          else
            @message = Message.new(from: from, helo: @helo, peer: @peer, secure: @secure)
            Reply.ok
          end
        end

        def rcpt_to(to)
          case @message
          when nil then Reply.new(503, "MAIL is required before RCPT")
          else
            @message.to << to
            Reply.ok
          end
        end

        def data
          case @message&.to
          in nil | [] then Reply.new(503, "RCPT is required before DATA")
          else
            @state = :data
            Reply.new(354, "End data with <CR><LF>.<CR><LF>")
          end
        end

        def rset
          reset(@helo)
          Reply.ok
        end

        def quit
          shutdown
          Reply.new(221, "Bye")
        end

        # RFC 5321 4.5.2: a line of a single dot ends the message, and a
        # leading dot on any other line was stuffed by the client on the way
        # out — it comes back off here.
        def collect(line, &block)
          case line
          when "." then finish(&block)
          else append(line)
          end
        end

        # nil while the message is still coming: mid-DATA there is nothing to
        # say. Past the limit there is nothing to say either — the client is
        # still sending, and reading its body as commands would answer every
        # line of it with a 500. Drop the rest and hold the 552 until the
        # terminating dot (RFC 1870 6.2).
        def append(line)
          @message.data << line.sub(/\A\./, "") << CRLF

          case @message.bytesize > @maximum_message_size
          when true then @state = :discard
          end

          nil
        end

        def discard(line)
          case line
          when "."
            reset(@helo)
            Reply.new(552, "Message exceeds #{@maximum_message_size} bytes")
          end
        end

        def finish
          @message.then do |message|
            reset(@helo)
            yield(message)
          end
        end

        def reset(helo)
          @helo = helo
          @message = nil
          @state = :command
        end

        # "FROM:<me@example.com> SIZE=42" -> "me@example.com". The SIZE
        # parameter is there because EHLO advertised the extension; an address
        # has no spaces in it, so the first token after the verb is all of it.
        # A null sender (<>) lands here as "".
        def address(argument)
          argument.sub(/\A[A-Za-z]+:\s*/, "").split(/\s/).first.to_s.delete("<>")
        end
    end
  end
end
