# frozen_string_literal: true

require "protocol/smtp/message"

describe Protocol::SMTP::Message do
  let(:message) {subject.new(from: "me@example.com", helo: "client", peer: "127.0.0.1")}

  it "keeps the envelope separate from the headers" do
    message.to << "you@example.com"
    message.data << "From: someone-else@example.com\r\n\r\nHello\r\n"

    expect(message.from).to be == "me@example.com"
    expect(message.headers["from"]).to be == "someone-else@example.com"
  end

  it "unfolds a continued header" do
    message.data << "Subject: a very\r\n  long subject\r\nTo: you@example.com\r\n\r\nBody\r\n"

    expect(message.subject).to be == "a very long subject"
    expect(message.headers["to"]).to be == "you@example.com"
  end

  it "separates the body at the blank line" do
    message.data << "Subject: Hi\r\n\r\nline one\r\nline two\r\n"

    expect(message.body).to be == "line one\r\nline two\r\n"
  end

  with "no headers at all" do
    it "has no headers and an empty body" do
      message.data << "just text\r\n"

      expect(message.headers).to be == {}
      expect(message.body).to be == ""
    end
  end

  it "reports its size in bytes" do
    message.data << "Ω\r\n"

    expect(message.bytesize).to be == 4
  end

  it "is not secure unless it arrived over TLS" do
    expect(message).not.to be(:secure?)
    expect(subject.new(from: "a@b", secure: true)).to be(:secure?)
  end

  it "deconstructs for pattern matching" do
    message.to << "you@example.test"
    message.data << "Subject: URGENT\r\n\r\nnow\r\n"

    case message
    in {to: [/@example\.test\z/, *], subject: /urgent/i}
      expect(message.peer).to be == "127.0.0.1"
    end

    case message
    in [from, [recipient]]
      expect(from).to be == "me@example.com"
      expect(recipient).to be == "you@example.test"
    end
  end
end
