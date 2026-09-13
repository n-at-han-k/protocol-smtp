# frozen_string_literal: true

require_relative "connection"
require_relative "message"
require_relative "reply"

module Protocol
  module SMTP
    # The server side of an SMTP conversation: RFC 5321's command/reply state
    # machine over a stream.
    #
    #   server.write_greeting
    #
    #   while message = server.read_message
    #     server.write_reply(Protocol::SMTP::Reply.ok("queued"))
    #   end
    #
    # #read_message answers every command the protocol itself owns and hands
    # back each complete message; the reply to the message is the caller's to
    # write. Who drives that loop, what an application is allowed to return,
    # and when the stream is closed are all somebody else's business —
    # async-smtp's, for a socket on a reactor.
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

      # In SMTP the server talks first.
      #
      # @parameter reply [Reply] What to greet the client with.
      def write_greeting(reply = Reply.new(220, "#{@domain} ESMTP"))
        write_reply(reply)
      end

      # Read lines, answering each command the state machine owns, until
      # either a message is complete or the client is finished.
      #
      # @returns [Message | Nil] The next complete message, or nil when the
      #   client quit or the stream ended.
      def read_message
        message = nil

        while message.nil? && !closed? && (line = read_line)
          receive(line).then do |result|
            case result
            when Message then message = result
            when Reply then write_reply(result)
            end
          end
        end

        message
      end

      # The reply to a message, which is the one reply in the conversation the
      # protocol has no opinion about.
      #
      # @parameter reply [Reply | Nil] Nil says nothing, for a caller that has
      #   already answered.
      def write_reply(reply)
        case reply
        when nil then nil
        else write_line(reply.to_s)
        end
      end

      private

        def receive(line)
          case @state
          when :data then collect(line)
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
            write_reply(Reply.new(220, "Ready to start TLS"))
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
        def collect(line)
          case line
          when "." then finish
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

        # The message, with the transaction it arrived in wound up: the reply
        # to it is written later, by whoever asked for it.
        def finish
          @message.tap do
            reset(@helo)
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

__END__

require "duplex"

# Drive a scripted conversation to its end — the loop async-smtp runs — and
# hand back the stream it happened over, plus the messages it produced.
converse = lambda do |*script, reply: Protocol::SMTP::Reply.ok("queued"), **options|
  stream = Protocol::SMTP::Duplex.new(script.map {|line| "#{line}\r\n"}.join)
  server = Protocol::SMTP::Server.new(stream, domain: "mail.example.com", **options)
  messages = []

  server.write_greeting

  while message = server.read_message
    messages << message
    server.write_reply(reply)
  end

  [stream, messages, server]
end

describe "protocol/smtp/server" do
  it "answers each command of a transaction in order, and hands over one message" do
    stream, messages = converse.call(
      "EHLO client.example.com",
      "MAIL FROM:<me@example.com>",
      "RCPT TO:<you@example.com>",
      "DATA",
      "Subject: Hello",
      "",
      "Body text",
      ".",
      "QUIT",
    )

    stream.codes.should == [220, 250, 250, 250, 354, 250, 221]

    messages.length.should == 1
    messages.first.from.should == "me@example.com"
    messages.first.to.should == ["you@example.com"]
    messages.first.subject.should == "Hello"
    messages.first.body.should == "Body text\r\n"
    messages.first.helo.should == "client.example.com"
  end

  it "leaves the stream open for whoever owns it to close" do
    stream, = converse.call("QUIT")

    stream.should.not.be.closed
  end

  it "advertises its extensions on EHLO" do
    stream, = converse.call("EHLO client.example.com")

    stream.lines.should == [
      "220 mail.example.com ESMTP",
      "250-mail.example.com greets client.example.com",
      "250-SIZE #{Protocol::SMTP::Server::DEFAULT_MAXIMUM_MESSAGE_SIZE}",
      "250 8BITMIME",
    ]
  end

  it "treats a greeting with no domain as a syntax error" do
    converse.call("EHLO", "HELO").first.codes.should == [220, 501, 501]
  end

  it "refuses each command until its turn (RFC 5321 4.3.2)" do
    stream, = converse.call(
      "MAIL FROM:<me@example.com>",
      "EHLO client",
      "RCPT TO:<you@example.com>",
      "DATA",
      "MAIL FROM:<me@example.com>",
      "DATA",
    )

    stream.codes.should == [220, 503, 250, 503, 503, 250, 503]
  end

  it "answers an unknown or unimplemented command without ending the conversation" do
    stream, = converse.call("WHAT", "VRFY someone", "EXPN list", "HELP", "AUTH PLAIN abc", "NOOP", "MAIL", "RCPT")

    stream.codes.should == [220, 500, 502, 502, 502, 502, 250, 501, 501]
  end

  it "abandons the transaction on RSET but keeps the greeting" do
    stream, messages = converse.call(
      "HELO client",
      "MAIL FROM:<me@example.com>",
      "RSET",
      "RCPT TO:<you@example.com>",
      "MAIL FROM:<other@example.com>",
      "RCPT TO:<you@example.com>",
      "DATA",
      ".",
    )

    stream.codes.should == [220, 250, 250, 250, 503, 250, 250, 354, 250]
    messages.first.from.should == "other@example.com"
    messages.first.helo.should == "client"
  end

  it "starts the transaction over on a re-issued MAIL FROM (RFC 5321 4.1.1.2)" do
    stream, messages = converse.call(
      "HELO client",
      "MAIL FROM:<first@example.com>",
      "RCPT TO:<you@example.com>",
      "MAIL FROM:<second@example.com>",
      "RCPT TO:<other@example.com>",
      "DATA",
      ".",
    )

    stream.codes.should == [220, 250, 250, 250, 250, 250, 354, 250]
    messages.first.from.should == "second@example.com"
    messages.first.to.should == ["other@example.com"]
  end

  it "takes the address out of a command and ignores its parameters" do
    _, messages = converse.call(
      "HELO client",
      "MAIL FROM:<me@example.com> SIZE=42 BODY=8BITMIME",
      "RCPT TO:<one@example.com> NOTIFY=NEVER",
      "RCPT TO:<two@example.com>",
      "DATA",
      ".",
    )

    messages.first.from.should == "me@example.com"
    messages.first.to.should == ["one@example.com", "two@example.com"]
  end

  it "accepts a null sender, as a bounce requires" do
    stream, messages = converse.call("HELO client", "MAIL FROM:<>", "RCPT TO:<you@example.com>", "DATA", ".")

    stream.codes.should == [220, 250, 250, 250, 354, 250]
    messages.first.from.should == ""
  end

  it "treats the verb as case insensitive (RFC 5321 2.4)" do
    stream, = converse.call("ehlo client", "mail from:<me@example.com>", "Rcpt To:<you@example.com>", "data", ".")

    stream.codes.should == [220, 250, 250, 250, 354, 250]
  end

  it "unstuffs a leading dot from the body (RFC 5321 4.5.2)" do
    _, messages = converse.call(
      "HELO client",
      "MAIL FROM:<me@example.com>",
      "RCPT TO:<you@example.com>",
      "DATA",
      "..hidden",
      "...two",
      "regular",
      ".",
    )

    messages.first.data.should == ".hidden\r\n..two\r\nregular\r\n"
  end

  it "keeps reading an over-sized body and refuses it at the terminating dot" do
    # Answering mid-DATA would reply to the rest of the message as if it were
    # commands (RFC 1870 6.2):
    stream, messages = converse.call(
      "HELO client",
      "MAIL FROM:<me@example.com>",
      "RCPT TO:<you@example.com>",
      "DATA",
      "x" * 100,
      "MAIL FROM:<not-a-command@example.com>",
      ".",
      "NOOP",
      maximum_message_size: 64,
    )

    stream.codes.should == [220, 250, 250, 250, 354, 552, 250]
    messages.should.be.empty
  end

  it "advertises STARTTLS, upgrades the stream, and forgets the transaction" do
    upgraded = Protocol::SMTP::Duplex.new("EHLO client\r\nQUIT\r\n")

    stream, _, server = converse.call(
      "EHLO client",
      "MAIL FROM:<me@example.com>",
      "STARTTLS",
      starttls: proc {upgraded},
    )

    stream.lines.should == [
      "220 mail.example.com ESMTP",
      "250-mail.example.com greets client",
      "250-SIZE #{Protocol::SMTP::Server::DEFAULT_MAXIMUM_MESSAGE_SIZE}",
      "250-8BITMIME",
      "250 STARTTLS",
      "250 Ok",
      "220 Ready to start TLS",
    ]

    # Everything after the upgrade went over the new stream, which no longer
    # offers STARTTLS, and the client had to introduce itself again:
    upgraded.lines.should == [
      "250-mail.example.com greets client",
      "250-SIZE #{Protocol::SMTP::Server::DEFAULT_MAXIMUM_MESSAGE_SIZE}",
      "250 8BITMIME",
      "221 Bye",
    ]

    server.should.be.secure
  end

  it "neither advertises nor allows TLS it cannot do" do
    stream, = converse.call("EHLO client", "STARTTLS")

    stream.codes.should == [220, 250, 454]
    stream.lines.should.not.include "250 STARTTLS"
  end

  it "ends the conversation at the end of the stream" do
    converse.call("HELO client", "MAIL FROM:<me@example.com>").first.codes.should == [220, 250, 250]
  end

  it "refuses an over-long command line rather than guessing" do
    stream = Protocol::SMTP::Duplex.new("HELO #{"x" * 100}\r\n")
    server = Protocol::SMTP::Server.new(stream, maximum_line_length: 32)
    server.write_greeting

    lambda { server.read_message }.should.raise(Protocol::SMTP::LineLengthError)
  end

  it "writes exactly the reply the caller answered with" do
    stream, = converse.call(
      "HELO client",
      "MAIL FROM:<me@example.com>",
      "RCPT TO:<you@example.com>",
      "DATA",
      ".",
      reply: Protocol::SMTP::Reply.rejected("Spam"),
    )

    stream.lines.last.should == "550 Spam"
  end

  it "says nothing for a caller with nothing to say" do
    # The reply to a message is not the protocol's to invent:
    stream, = converse.call(
      "HELO client",
      "MAIL FROM:<me@example.com>",
      "RCPT TO:<you@example.com>",
      "DATA",
      ".",
      "NOOP",
      reply: nil,
    )

    stream.codes.should == [220, 250, 250, 250, 354, 250]
  end
end
