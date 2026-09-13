# frozen_string_literal: true

require "protocol/smtp/client"
require "protocol/smtp/duplex"

describe Protocol::SMTP::Client do
  let(:stream) {Protocol::SMTP::Duplex.new(script.map {|line| "#{line}\r\n"}.join)}
  let(:client) {subject.new(stream)}

  # What the client actually sent, one entry per line.
  def sent = stream.lines

  with "a greeting" do
    let(:script) {["220 mail.example.com ESMTP"]}

    it "reads what the server said first" do
      expect(client.greeting.code).to be == 220
      expect(client.greeting.text).to be == "mail.example.com ESMTP"
    end

    it "only reads it once" do
      client.greeting

      expect(client.greeting).to be == client.greeting
    end
  end

  with "a multi-line reply" do
    let(:script) do
      [
        "220 mail.example.com ESMTP",
        "250-mail.example.com greets client",
        "250-SIZE 35651584",
        "250-AUTH PLAIN LOGIN",
        "250-STARTTLS",
        "250 8BITMIME",
      ]
    end

    it "reads every line as one reply" do
      reply = client.ehlo("client")

      expect(reply.code).to be == 250
      expect(reply.lines.size).to be == 5
    end

    it "parses the extensions, keeping their arguments" do
      client.ehlo("client")

      expect(client.extensions.keys).to be == ["SIZE", "AUTH", "STARTTLS", "8BITMIME"]
      expect(client).to be(:starttls?)
      expect(client.mechanisms).to be == ["PLAIN", "LOGIN"]
      expect(client.maximum_message_size).to be == 35_651_584
    end
  end

  with "a server that does not know EHLO" do
    let(:script) {["220 mail.example.com ESMTP", "500 Unknown command", "250 mail.example.com"]}

    it "falls back to HELO (RFC 5321 2.2.1)" do
      expect(client.hello("client").code).to be == 250

      expect(sent).to be == ["EHLO client", "HELO client"]
      expect(client.extensions).to be == {}
    end
  end

  with "a malformed reply" do
    let(:script) {["not a reply at all"]}

    it "refuses to guess" do
      expect{client.greeting}.to raise_exception(Protocol::SMTP::InvalidReplyError)
    end
  end

  with "a stream that ends mid-reply" do
    let(:script) {["250-first"]}

    it "reports the peer went away" do
      expect{client.read_reply}.to raise_exception(Protocol::SMTP::ClosedError)
    end
  end

  with "a whole transaction" do
    let(:script) do
      [
        "220 mail.example.com ESMTP",
        "250-mail.example.com greets client",
        "250 8BITMIME",
        "250 Ok",
        "250 Ok",
        "250 Ok",
        "354 End data with <CR><LF>.<CR><LF>",
        "250 Queued",
      ]
    end

    it "sends the commands in order, then the body and its terminator" do
      reply = client.deliver(
        from:   "me@example.com",
        to:     ["one@example.com", "two@example.com"],
        body:   "Subject: Hi\r\n\r\nBody\r\n",
        domain: "client",
      )

      expect(reply.code).to be == 250
      expect(sent).to be == [
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
  end

  with "a body containing a bare dot" do
    let(:script) {["354 Go ahead", "250 Queued"]}

    it "stuffs it so it cannot end the message (RFC 5321 4.5.2)" do
      client.data(".\r\n.hidden\r\ntext\r\n")

      expect(sent).to be == ["DATA", "..", "..hidden", "text", "."]
    end
  end

  with "a refused recipient" do
    let(:script) do
      [
        "220 mail.example.com ESMTP",
        "250 mail.example.com greets client",
        "250 Ok",
        "550 No such user",
      ]
    end

    it "stops the transaction rather than sending the body" do
      expect do
        client.deliver(from: "me@example.com", to: "nobody@example.com", body: "Hi", domain: "client")
      end.to raise_exception(Protocol::SMTP::ReplyError) do |error|
        expect(error.reply.code).to be == 550
      end

      expect(sent).not.to be(:include?, "DATA")
    end
  end

  with "AUTH PLAIN" do
    let(:script) {["235 Authenticated"]}

    it "sends the credentials as one base64 blob (RFC 4616)" do
      expect(client.auth_plain("user", "pass").code).to be == 235

      expect(sent).to be == ["AUTH PLAIN #{["\0user\0pass"].pack("m0")}"]
    end
  end

  with "AUTH LOGIN" do
    let(:script) {["334 VXNlcm5hbWU6", "334 UGFzc3dvcmQ6", "235 Authenticated"]}

    it "answers each challenge in turn" do
      expect(client.auth_login("user", "pass").code).to be == 235

      expect(sent).to be == ["AUTH LOGIN", ["user"].pack("m0"), ["pass"].pack("m0")]
    end
  end

  with "#authenticate" do
    let(:script) {["220 ESMTP", "250-greets\r\n250 AUTH LOGIN", "334 x", "334 y", "235 Ok"]}

    it "picks a mechanism the server offered" do
      client.ehlo("client")

      expect(client.authenticate("user", "pass").code).to be == 235
      expect(sent).to be(:include?, "AUTH LOGIN")
    end
  end

  with "a server offering nothing we implement" do
    let(:script) {["220 ESMTP", "250-greets", "250 AUTH GSSAPI"]}

    it "says so instead of sending credentials" do
      client.ehlo("client")

      expect{client.authenticate("user", "pass")}.to raise_exception(Protocol::SMTP::AuthenticationError)
    end
  end

  with "STARTTLS" do
    let(:script) {["220 Ready to start TLS"]}

    it "asks, and leaves the upgrade to the caller" do
      expect(client.starttls.code).to be == 220
      expect(sent).to be == ["STARTTLS"]
    end
  end

  with "QUIT" do
    let(:script) {["221 Bye"]}

    it "ends the conversation but leaves the stream to its owner" do
      expect(client.quit.code).to be == 221
      expect(client).to be(:closed?)
      expect(stream).not.to be(:closed?)
    end
  end
end

describe Protocol::SMTP::Client do
  with "#transaction on an established session" do
    let(:stream) {Protocol::SMTP::Duplex.new(["250 Ok", "250 Ok", "354 Go", "250 Queued"].map {|l| "#{l}\r\n"}.join)}
    let(:client) {subject.new(stream)}

    it "sends the envelope and body without another EHLO" do
      expect(client.transaction(from: "me@example.com", to: "you@example.com", body: "Hi\r\n").code).to be == 250

      expect(stream.lines).to be == [
        "MAIL FROM:<me@example.com>",
        "RCPT TO:<you@example.com>",
        "DATA",
        "Hi",
        ".",
      ]
    end
  end
end
