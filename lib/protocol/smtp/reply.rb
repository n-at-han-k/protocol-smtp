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

      # @parameter code [Integer] The three digit reply code.
      # @parameter lines [String | Array(String)] The text of the reply.
      def initialize(code, lines)
        @code = Integer(code)
        @lines = Array(lines)

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
