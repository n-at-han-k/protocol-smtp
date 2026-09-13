# frozen_string_literal: true

require_relative "connection"
require_relative "reply"

module Protocol
  module SMTP
    # The client side of the conversation: send a command, read the reply it
    # answers with.
    #
    #   client = Protocol::SMTP::Client.new(stream)
    #   client.deliver(from: "me@example.com", to: "you@example.com", body: message)
    #   client.quit
    #
    # Every command returns its Reply rather than raising on one, because
    # which codes are fatal depends on what you are doing — #deliver, which
    # has to get a whole transaction through in order, is the one that insists.
    class Client < Connection
      # RFC 5321 4.2: three digits, then a space on the last line of a reply
      # and a hyphen on every line before it. The text is optional.
      REPLY_LINE = /\A(?<code>\d{3})(?<continued>[ \-]?)(?<text>.*)\z/m

      # The mechanisms #authenticate knows how to perform, best first.
      MECHANISMS = ["PLAIN", "LOGIN"].freeze

      # In SMTP the server talks first; this is what it said.
      # @returns [Reply]
      def greeting = @greeting ||= read_reply

      # @parameter domain [String] The domain to introduce ourselves as.
      # @returns [Reply] The server's reply, whose lines are its extensions.
      def ehlo(domain)
        greeting

        command("EHLO #{domain}").tap do |reply|
          case reply.positive?
          when true then @extensions = parse_extensions(reply)
          end
        end
      end

      # @parameter domain [String] The domain to introduce ourselves as.
      # @returns [Reply]
      def helo(domain)
        greeting
        command("HELO #{domain}").tap { @extensions = {} }
      end

      # EHLO, falling back to HELO for a server that does not know it
      # (RFC 5321 2.2.1). The extension list is empty in that case.
      #
      # @parameter domain [String] The domain to introduce ourselves as.
      # @returns [Reply]
      def hello(domain)
        ehlo(domain).then do |reply|
          case reply.positive?
          when true then reply
          else helo(domain)
          end
        end
      end

      # What the last EHLO advertised: an upper case keyword for each
      # extension, mapped to the rest of its line.
      #
      # @returns [Hash(String, String)]
      def extensions = @extensions ||= {}

      # @returns [Boolean] Whether the server offered to upgrade to TLS.
      def starttls? = extensions.key?("STARTTLS")

      # @returns [Array(String)] The mechanisms the server offered, upper case.
      def mechanisms = extensions.fetch("AUTH", "").upcase.split

      # @returns [Integer | Nil] The largest message the server will take.
      def maximum_message_size
        extensions["SIZE"].then do |size|
          case size
          when nil, "" then nil
          else Integer(size, exception: false)
          end
        end
      end

      # Ask to upgrade the connection (RFC 3207). On a 220 the caller has to
      # replace {Connection#stream} with the encrypted one and then start over
      # with a fresh EHLO — the extension list before and after an upgrade are
      # not the same thing, which is the point of doing it.
      #
      # @returns [Reply]
      def starttls = command("STARTTLS")

      # @returns [Reply]
      def mail_from(address) = command("MAIL FROM:<#{address}>")

      # @returns [Reply]
      def rcpt_to(address) = command("RCPT TO:<#{address}>")

      # @returns [Reply]
      def reset = command("RSET")

      # @returns [Reply]
      def noop = command("NOOP")

      # Say goodbye and read the 221. The stream stays open: whoever opened it
      # closes it.
      #
      # @returns [Reply]
      def quit
        command("QUIT").tap { shutdown }
      end

      # RFC 4616: the credentials go in one base64 blob, NUL separated, with an
      # empty authorisation identity in front.
      #
      # @returns [Reply]
      def auth_plain(username, password)
        command("AUTH PLAIN #{encode("\0#{username}\0#{password}")}")
      end

      # The same credentials, one 334 challenge at a time. Only for servers
      # that offer LOGIN and not PLAIN; the challenge text is ignorable.
      #
      # @returns [Reply]
      def auth_login(username, password)
        expect(command("AUTH LOGIN"), 334)
        expect(command(encode(username)), 334)
        command(encode(password))
      end

      # Authenticate using the best mechanism the server offered.
      #
      # @parameter username [String]
      # @parameter password [String]
      # @returns [Reply]
      # @raises [AuthenticationError] If no offered mechanism is implemented.
      def authenticate(username, password)
        (MECHANISMS & mechanisms).first.then do |mechanism|
          case mechanism
          when "PLAIN" then auth_plain(username, password)
          when "LOGIN" then auth_login(username, password)
          else
            raise AuthenticationError, "No supported mechanism in #{mechanisms.inspect}!"
          end
        end
      end

      # DATA, then the message, then the terminating dot. A body line that
      # starts with a dot gets another one so it cannot be mistaken for that
      # terminator (RFC 5321 4.5.2).
      #
      # @parameter body [String] The message, headers and all.
      # @returns [Reply] What the server made of it.
      def data(body)
        expect(command("DATA"), 354)

        body.each_line do |line|
          write_line(line.chomp.sub(/\A\./, ".."))
        end

        write_line(".")
        read_reply
      end

      # One whole transaction on a connection that has already introduced
      # itself, refusing to carry on past a reply that means it cannot
      # succeed. This is the half of #deliver worth repeating: a session can
      # carry any number of transactions, and only one EHLO.
      #
      # @parameter from [String] The envelope sender.
      # @parameter to [String | Array(String)] The envelope recipients.
      # @parameter body [String] The message, headers and all.
      # @returns [Reply] The reply to the message itself.
      # @raises [ReplyError] If any step of the transaction was refused.
      def transaction(from:, to:, body:)
        expect(mail_from(from), 250)

        Array(to).each do |address|
          expect(rcpt_to(address), 250)
        end

        expect(data(body), 250)
      end

      # Introduce ourselves and send one message.
      #
      # @parameter from [String] The envelope sender.
      # @parameter to [String | Array(String)] The envelope recipients.
      # @parameter body [String] The message, headers and all.
      # @parameter domain [String] The domain to introduce ourselves as.
      # @returns [Reply] The reply to the message itself.
      # @raises [ReplyError] If any step of the transaction was refused.
      def deliver(from:, to:, body:, domain: "localhost")
        expect(hello(domain), 250)

        transaction(from: from, to: to, body: body)
      end

      # @parameter line [String] The command line, without its terminator.
      # @returns [Reply]
      def command(line)
        write_line(line)
        read_reply
      end

      # A multi-line reply repeats its code on every line, with a hyphen
      # instead of a space until the last one (RFC 5321 4.2.1).
      #
      # @returns [Reply]
      def read_reply
        code = nil
        lines = []
        continued = true

        while continued
          parse_reply_line(read_line).then do |parsed|
            code = parsed[0]
            lines << parsed[1]
            continued = parsed[2]
          end
        end

        Reply.new(code, lines)
      end

      private

        def parse_reply_line(line)
          case line
          when nil then raise ClosedError, "Connection closed while reading a reply!"
          when REPLY_LINE
            [Integer($~[:code]), $~[:text], $~[:continued] == "-"]
          else
            raise InvalidReplyError, "Invalid reply line: #{line.inspect}!"
          end
        end

        # The first line of an EHLO reply is a greeting, not an extension; the
        # rest are "KEYWORD arguments" (RFC 5321 4.1.1.1).
        def parse_extensions(reply)
          reply.lines.drop(1).to_h do |line|
            line.strip.split(" ", 2).then do |keyword, arguments|
              [keyword.to_s.upcase, arguments.to_s]
            end
          end
        end

        def encode(string) = [string].pack("m0")

        def expect(reply, code)
          case reply.code
          when code then reply
          else raise ReplyError, reply
          end
        end
    end
  end
end

__END__

require "duplex"

# A client whose server has already said everything it is going to say.
scripted = lambda do |*script|
  stream = Protocol::SMTP::Duplex.new(script.map {|line| "#{line}\r\n"}.join)

  [Protocol::SMTP::Client.new(stream), stream]
end

describe "protocol/smtp/client" do
  it "reads what the server said first, once" do
    client, = scripted.call("220 mail.example.com ESMTP")

    client.greeting.code.should == 220
    client.greeting.text.should == "mail.example.com ESMTP"
    client.greeting.should.be.identical_to client.greeting
  end

  it "reads a multi-line reply as one reply, and its lines as extensions" do
    client, = scripted.call(
      "220 mail.example.com ESMTP",
      "250-mail.example.com greets client",
      "250-SIZE 35651584",
      "250-AUTH PLAIN LOGIN",
      "250-STARTTLS",
      "250 8BITMIME",
    )

    reply = client.ehlo("client")
    reply.code.should == 250
    reply.lines.length.should == 5

    client.extensions.keys.should == ["SIZE", "AUTH", "STARTTLS", "8BITMIME"]
    client.should.be.starttls
    client.mechanisms.should == ["PLAIN", "LOGIN"]
    client.maximum_message_size.should == 35_651_584
  end

  it "falls back to HELO for a server that does not know EHLO (RFC 5321 2.2.1)" do
    client, stream = scripted.call("220 mail.example.com ESMTP", "500 Unknown command", "250 mail.example.com")

    client.hello("client").code.should == 250
    stream.lines.should == ["EHLO client", "HELO client"]
    client.extensions.should == {}
  end

  it "refuses to guess at anything that is not a reply" do
    client, = scripted.call("not a reply at all")

    lambda { client.greeting }.should.raise(Protocol::SMTP::InvalidReplyError)
  end

  it "reports a peer that went away mid-reply" do
    client, = scripted.call("250-first")

    lambda { client.read_reply }.should.raise(Protocol::SMTP::ClosedError)
  end

  it "sends a whole transaction in order, then the body and its terminator" do
    client, stream = scripted.call(
      "220 mail.example.com ESMTP",
      "250-mail.example.com greets client",
      "250 8BITMIME",
      "250 Ok",
      "250 Ok",
      "250 Ok",
      "354 End data with <CR><LF>.<CR><LF>",
      "250 Queued",
    )

    reply = client.deliver(
      from: "me@example.com",
      to: ["one@example.com", "two@example.com"],
      body: "Subject: Hi\r\n\r\nBody\r\n",
      domain: "client",
    )

    reply.code.should == 250
    stream.lines.should == [
      "EHLO client",
      "MAIL FROM:<me@example.com>",
      "RCPT TO:<one@example.com>",
      "RCPT TO:<two@example.com>",
      "DATA",
      "Subject: Hi",
      "",
      "Body",
      ".",
    ]
  end

  it "runs a transaction on a session that has already introduced itself" do
    client, stream = scripted.call("250 Ok", "250 Ok", "354 Go", "250 Queued")

    client.transaction(from: "me@example.com", to: "you@example.com", body: "Hi\r\n").code.should == 250
    stream.lines.should == ["MAIL FROM:<me@example.com>", "RCPT TO:<you@example.com>", "DATA", "Hi", "."]
  end

  it "stuffs a leading dot so the body cannot end the message (RFC 5321 4.5.2)" do
    client, stream = scripted.call("354 Go ahead", "250 Queued")

    client.data(".\r\n.hidden\r\ntext\r\n")
    stream.lines.should == ["DATA", "..", "..hidden", "text", "."]
  end

  it "stops a transaction rather than sending a body nobody will take" do
    client, stream = scripted.call(
      "220 mail.example.com ESMTP",
      "250 mail.example.com greets client",
      "250 Ok",
      "550 No such user",
    )

    error = lambda do
      client.deliver(from: "me@example.com", to: "nobody@example.com", body: "Hi", domain: "client")
    end.should.raise(Protocol::SMTP::ReplyError)

    error.reply.code.should == 550
    stream.lines.should.not.include "DATA"
  end

  it "sends AUTH PLAIN credentials as one base64 blob (RFC 4616)" do
    client, stream = scripted.call("235 Authenticated")

    client.auth_plain("user", "pass").code.should == 235
    stream.lines.should == ["AUTH PLAIN #{["\0user\0pass"].pack("m0")}"]
  end

  it "answers each AUTH LOGIN challenge in turn" do
    client, stream = scripted.call("334 VXNlcm5hbWU6", "334 UGFzc3dvcmQ6", "235 Authenticated")

    client.auth_login("user", "pass").code.should == 235
    stream.lines.should == ["AUTH LOGIN", ["user"].pack("m0"), ["pass"].pack("m0")]
  end

  it "picks a mechanism the server offered" do
    client, stream = scripted.call("220 ESMTP", "250-greets", "250 AUTH LOGIN", "334 x", "334 y", "235 Ok")
    client.ehlo("client")

    client.authenticate("user", "pass").code.should == 235
    stream.lines.should.include "AUTH LOGIN"
  end

  it "says so rather than sending credentials nothing can carry" do
    client, = scripted.call("220 ESMTP", "250-greets", "250 AUTH GSSAPI")
    client.ehlo("client")

    lambda { client.authenticate("user", "pass") }.should.raise(Protocol::SMTP::AuthenticationError)
  end

  it "asks for STARTTLS and leaves the upgrade to the caller" do
    client, stream = scripted.call("220 Ready to start TLS")

    client.starttls.code.should == 220
    stream.lines.should == ["STARTTLS"]
  end

  it "ends the conversation on QUIT but leaves the stream to its owner" do
    client, stream = scripted.call("221 Bye")

    client.quit.code.should == 221
    client.should.be.closed
    stream.should.not.be.closed
  end
end
