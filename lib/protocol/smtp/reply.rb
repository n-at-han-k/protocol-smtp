# frozen_string_literal: true

module Protocol
  module SMTP
    # What the server says back. A reply is a code and one or more lines; on
    # the wire every line but the last is joined to its code by a hyphen
    # rather than a space, which is how the client knows more is coming
    # (RFC 5321 4.2.1).
    class Reply
      CRLF = "\r\n"

      # The replies the state machine itself sends. Anything an application
      # wants to say is its own Reply.
      def self.ok(text = "Ok") = new(250, text)
      def self.rejected(text = "Message rejected") = new(550, text)

      # A CRLF in the text would end the line early and let whatever follows
      # it pass for a reply of its own. An application that quotes a subject
      # line or an address back at the client — both of which came from the
      # client — would otherwise be handing it a reply stream to write.
      SEPARATORS = /[\r\n]+/

      # @parameter code [Integer] The three digit reply code.
      # @parameter lines [String | Array(String)] The text of the reply.
      def initialize(code, lines)
        @code = Integer(code)
        @lines = Array(lines).map {|line| line.to_s.gsub(SEPARATORS, " ")}

        case @lines
        when [] then @lines = [""]
        end
      end

      # @attribute [Integer] The three digit reply code.
      attr_reader :code

      # @attribute [Array(String)] The text of the reply, one entry per line.
      attr_reader :lines

      # @returns [String] The reply as it goes on the wire, terminator excluded.
      def to_s
        lines[0..-2].map { |line| "#{code}-#{line}" }.push("#{code} #{lines.last}").join(CRLF)
      end

      # @returns [String] The reply's text, lines joined by a space.
      def text = lines.join(" ")

      # 2xx and 3xx are the codes that let the conversation continue.
      # @returns [Boolean]
      def positive? = code < 400

      # A 4xx is worth retrying later; a 5xx is not (RFC 5321 4.2.1).
      # @returns [Boolean]
      def transient? = code >= 400 && code < 500

      # @returns [Boolean]
      def permanent? = code >= 500

      # Enables `in [250, [text, *]]`
      def deconstruct = [code, lines]

      # Enables `in {code: 250..299}`
      def deconstruct_keys(_keys) = { code:, lines: }

      def ==(other)
        other.is_a?(Reply) && other.code == code && other.lines == lines
      end
      alias eql? ==

      def hash = [code, lines].hash

      def inspect = "#<#{self.class} #{code} #{text}>"
    end
  end
end

__END__

describe "protocol/smtp/reply" do
  it "puts a single line reply on one line" do
    reply = Protocol::SMTP::Reply.new(250, "Ok")

    reply.to_s.should == "250 Ok"
    reply.should.be.positive
    reply.should.not.be.transient
    reply.should.not.be.permanent
  end

  it "joins every line but the last to its code with a hyphen (RFC 5321 4.2.1)" do
    reply = Protocol::SMTP::Reply.new(250, ["greets you", "SIZE 100", "8BITMIME"])

    reply.to_s.should == "250-greets you\r\n250-SIZE 100\r\n250 8BITMIME"
    reply.text.should == "greets you SIZE 100 8BITMIME"
  end

  it "still produces a valid line with no text at all" do
    Protocol::SMTP::Reply.new(220, nil).to_s.should == "220 "
  end

  it "refuses to let the text end the line" do
    # Whatever an application quotes back at a client came from that client:
    reply = Protocol::SMTP::Reply.ok("Queued \r\n550 Injected")

    reply.to_s.should == "250 Queued  550 Injected"
    reply.lines.length.should == 1
  end

  it "classifies 4xx as transient and 5xx as permanent" do
    Protocol::SMTP::Reply.new(451, "Try later").should.be.transient
    Protocol::SMTP::Reply.new(550, "No").should.be.permanent
    Protocol::SMTP::Reply.new(550, "No").should.not.be.positive
  end

  it "compares by code and lines" do
    Protocol::SMTP::Reply.ok.should == Protocol::SMTP::Reply.new(250, "Ok")
    Protocol::SMTP::Reply.ok.should.not == Protocol::SMTP::Reply.new(250, "Fine")
    {Protocol::SMTP::Reply.ok => true}[Protocol::SMTP::Reply.new(250, "Ok")].should.be.true
  end

  it "deconstructs for pattern matching" do
    matched = nil

    case Protocol::SMTP::Reply.rejected("Spam")
    in {code: 500.., lines: [text]}
      matched = text
    end

    matched.should == "Spam"
    Protocol::SMTP::Reply.ok.deconstruct.should == [250, ["Ok"]]
  end
end
