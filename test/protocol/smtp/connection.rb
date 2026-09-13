# frozen_string_literal: true

require "protocol/smtp/connection"
require "protocol/smtp/duplex"

describe Protocol::SMTP::Connection do
  let(:input) {""}
  let(:stream) {Protocol::SMTP::Duplex.new(input)}
  let(:connection) {subject.new(stream, maximum_line_length: 32)}

  with "a CRLF terminated line" do
    let(:input) {"HELO example.com\r\n"}

    it "reads it without its terminator" do
      expect(connection.read_line).to be == "HELO example.com"
    end
  end

  with "a bare LF terminated line" do
    let(:input) {"NOOP\n"}

    it "still reads it, rather than leaving the peer hanging" do
      expect(connection.read_line).to be == "NOOP"
    end
  end

  with "an empty stream" do
    it "reads nil at the end of the stream" do
      expect(connection.read_line).to be_nil
    end
  end

  with "an over-long line" do
    let(:input) {"#{"x" * 64}\r\n"}

    it "refuses it" do
      expect{connection.read_line}.to raise_exception(Protocol::SMTP::LineLengthError)
    end
  end

  with "a truncated line" do
    let(:input) {"NOOP"}

    it "reports the peer went away, not that the line was too long" do
      expect{connection.read_line}.to raise_exception(Protocol::SMTP::ClosedError)
    end
  end

  with "a line exactly at the limit, terminator included" do
    let(:input) {"#{"x" * 30}\r\n"}

    it "reads it" do
      expect(connection.read_line).to be == "x" * 30
    end
  end

  with "a line one byte past the limit" do
    let(:input) {"#{"x" * 31}\r\n"}

    it "refuses it" do
      expect{connection.read_line}.to raise_exception(Protocol::SMTP::LineLengthError)
    end
  end

  it "writes lines with CRLF" do
    connection.write_line("250 Ok")

    expect(stream.output).to be == "250 Ok\r\n"
  end

  with "#shutdown" do
    it "stops the conversation without closing the stream" do
      connection.shutdown

      expect(connection).to be(:closed?)
      expect(stream).not.to be(:closed?)
    end
  end

  with "#close" do
    it "closes the stream too" do
      connection.close

      expect(stream).to be(:closed?)
    end
  end
end
