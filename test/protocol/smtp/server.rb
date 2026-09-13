# frozen_string_literal: true

require "protocol/smtp/server"
require "protocol/smtp/duplex"

describe Protocol::SMTP::Server do
  let(:stream) {Protocol::SMTP::Duplex.new(script.map {|line| "#{line}\r\n"}.join)}
  let(:messages) {[]}

  # Drive the scripted conversation to its end — the loop async-smtp runs —
  # and return the reply codes that came back.
  def converse(server = subject.new(stream, domain: "mail.example.com", **options))
    server.write_greeting

    while message = server.read_message
      messages << message
      server.write_reply(Protocol::SMTP::Reply.ok("queued"))
    end

    stream.codes
  end

  let(:options) {{}}

  with "a complete transaction" do
    let(:script) do
      [
        "EHLO client.example.com",
        "MAIL FROM:<me@example.com>",
        "RCPT TO:<you@example.com>",
        "DATA",
        "Subject: Hello",
        "",
        "Body text",
        ".",
        "QUIT",
      ]
    end

    it "answers each command in order" do
      expect(converse).to be == [220, 250, 250, 250, 354, 250, 221]
    end

    it "hands the block one message" do
      converse

      expect(messages.size).to be == 1
      expect(messages.first.from).to be == "me@example.com"
      expect(messages.first.to).to be == ["you@example.com"]
      expect(messages.first.subject).to be == "Hello"
      expect(messages.first.body).to be == "Body text\r\n"
      expect(messages.first.helo).to be == "client.example.com"
    end

    it "leaves the stream open for whoever owns it to close" do
      converse

      expect(stream).not.to be(:closed?)
    end
  end

  with "EHLO" do
    let(:script) {["EHLO client.example.com"]}

    it "advertises its extensions" do
      converse

      expect(stream.lines).to be == [
        "220 mail.example.com ESMTP",
        "250-mail.example.com greets client.example.com",
        "250-SIZE #{Protocol::SMTP::Server::DEFAULT_MAXIMUM_MESSAGE_SIZE}",
        "250 8BITMIME",
      ]
    end
  end

  with "no domain" do
    let(:script) {["EHLO", "HELO"]}

    it "is a syntax error" do
      expect(converse).to be == [220, 501, 501]
    end
  end

  with "commands out of order" do
    let(:script) do
      [
        "MAIL FROM:<me@example.com>",
        "EHLO client",
        "RCPT TO:<you@example.com>",
        "DATA",
        "MAIL FROM:<me@example.com>",
        "DATA",
      ]
    end

    it "refuses each one until its turn" do
      expect(converse).to be == [220, 503, 250, 503, 503, 250, 503]
    end
  end

  with "unknown and unimplemented commands" do
    let(:script) {["WHAT", "VRFY someone", "EXPN list", "HELP", "AUTH PLAIN abc", "NOOP", "MAIL", "RCPT"]}

    it "says so without ending the conversation" do
      expect(converse).to be == [220, 500, 502, 502, 502, 502, 250, 501, 501]
    end
  end

  with "RSET" do
    let(:script) do
      [
        "HELO client",
        "MAIL FROM:<me@example.com>",
        "RSET",
        "RCPT TO:<you@example.com>",
        "MAIL FROM:<other@example.com>",
        "RCPT TO:<you@example.com>",
        "DATA",
        ".",
      ]
    end

    it "abandons the transaction but keeps the greeting" do
      expect(converse).to be == [220, 250, 250, 250, 503, 250, 250, 354, 250]
      expect(messages.first.from).to be == "other@example.com"
      expect(messages.first.helo).to be == "client"
    end
  end

  with "a re-issued MAIL FROM" do
    let(:script) do
      [
        "HELO client",
        "MAIL FROM:<first@example.com>",
        "RCPT TO:<you@example.com>",
        "MAIL FROM:<second@example.com>",
        "RCPT TO:<other@example.com>",
        "DATA",
        ".",
      ]
    end

    it "starts the transaction over (RFC 5321 4.1.1.2)" do
      expect(converse).to be == [220, 250, 250, 250, 250, 250, 354, 250]
      expect(messages.first.from).to be == "second@example.com"
      expect(messages.first.to).to be == ["other@example.com"]
    end
  end

  with "several recipients and parameters" do
    let(:script) do
      [
        "HELO client",
        "MAIL FROM:<me@example.com> SIZE=42 BODY=8BITMIME",
        "RCPT TO:<one@example.com> NOTIFY=NEVER",
        "RCPT TO:<two@example.com>",
        "DATA",
        ".",
      ]
    end

    it "takes the address and ignores the parameters" do
      converse

      expect(messages.first.from).to be == "me@example.com"
      expect(messages.first.to).to be == ["one@example.com", "two@example.com"]
    end
  end

  with "a null sender" do
    let(:script) {["HELO client", "MAIL FROM:<>", "RCPT TO:<you@example.com>", "DATA", "."]}

    it "accepts it, as a bounce requires" do
      expect(converse).to be == [220, 250, 250, 250, 354, 250]
      expect(messages.first.from).to be == ""
    end
  end

  with "lower case and mixed case commands" do
    let(:script) {["ehlo client", "mail from:<me@example.com>", "Rcpt To:<you@example.com>", "data", "."]}

    it "treats the verb as case insensitive (RFC 5321 2.4)" do
      expect(converse).to be == [220, 250, 250, 250, 354, 250]
    end
  end

  with "a dot stuffed body" do
    let(:script) do
      [
        "HELO client",
        "MAIL FROM:<me@example.com>",
        "RCPT TO:<you@example.com>",
        "DATA",
        "..hidden",
        "...two",
        "regular",
        ".",
      ]
    end

    it "unstuffs the leading dot (RFC 5321 4.5.2)" do
      converse

      expect(messages.first.data).to be == ".hidden\r\n..two\r\nregular\r\n"
    end
  end

  with "a message larger than the limit" do
    let(:options) {{maximum_message_size: 64}}
    let(:script) do
      [
        "HELO client",
        "MAIL FROM:<me@example.com>",
        "RCPT TO:<you@example.com>",
        "DATA",
        "x" * 100,
        "MAIL FROM:<not-a-command@example.com>",
        ".",
        "NOOP",
      ]
    end

    it "keeps reading the body and refuses it at the terminating dot" do
      expect(converse).to be == [220, 250, 250, 250, 354, 552, 250]
      expect(messages).to be(:empty?)
    end
  end

  with "STARTTLS" do
    let(:upgraded) {Protocol::SMTP::Duplex.new("EHLO client\r\nQUIT\r\n")}
    let(:options) {{starttls: proc {upgraded}}}
    let(:script) {["EHLO client", "MAIL FROM:<me@example.com>", "STARTTLS"]}

    it "advertises it, upgrades the stream, and forgets the transaction" do
      server = subject.new(stream, domain: "mail.example.com", **options)
      converse(server)

      expect(stream.lines).to be == [
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
      expect(upgraded.lines).to be == [
        "250-mail.example.com greets client",
        "250-SIZE #{Protocol::SMTP::Server::DEFAULT_MAXIMUM_MESSAGE_SIZE}",
        "250 8BITMIME",
        "221 Bye",
      ]

      expect(server).to be(:secure?)
    end
  end

  with "no TLS configured" do
    let(:script) {["EHLO client", "STARTTLS"]}

    it "does not advertise it, and refuses it" do
      expect(converse).to be == [220, 250, 454]
      expect(stream.lines).not.to be(:include?, "250 STARTTLS")
    end
  end

  with "a client that goes away" do
    let(:script) {["HELO client", "MAIL FROM:<me@example.com>"]}

    it "ends the conversation at the end of the stream" do
      expect(converse).to be == [220, 250, 250]
    end
  end

  with "an over-long command line" do
    let(:options) {{maximum_line_length: 32}}
    let(:script) {["HELO #{"x" * 100}"]}

    it "refuses the connection rather than guessing" do
      server = subject.new(stream, **options)
      server.write_greeting

      expect{server.read_message}.to raise_exception(Protocol::SMTP::LineLengthError)
    end
  end

  with "a caller that answers with its own reply" do
    let(:script) {["HELO client", "MAIL FROM:<me@example.com>", "RCPT TO:<you@example.com>", "DATA", "."]}

    it "writes exactly that" do
      server = subject.new(stream)
      server.write_greeting

      while server.read_message
        server.write_reply(Protocol::SMTP::Reply.rejected("Spam"))
      end

      expect(stream.lines.last).to be == "550 Spam"
    end
  end

  with "a caller with nothing to say" do
    let(:script) {["HELO client", "MAIL FROM:<me@example.com>", "RCPT TO:<you@example.com>", "DATA", ".", "NOOP"]}

    it "says nothing, because the reply to a message is not the protocol's" do
      server = subject.new(stream)
      server.write_greeting

      while server.read_message
        server.write_reply(nil)
      end

      expect(stream.codes).to be == [220, 250, 250, 250, 354, 250]
    end
  end
end
