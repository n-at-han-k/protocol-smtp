# frozen_string_literal: true

module Protocol
  module SMTP
    # One message, envelope and all. The envelope (#from, #to) is what the
    # conversation said; the headers are what the data claims. They disagree
    # more often than people expect, so both are here and neither is derived
    # from the other.
    class Message
      # @parameter from [String] The envelope sender; "" is the null sender.
      # @parameter helo [String | Nil] The domain the client introduced itself as.
      # @parameter peer [String | Nil] Where the client connected from.
      # @parameter secure [Boolean] Whether the message arrived over TLS.
      def initialize(from:, helo: nil, peer: nil, secure: false)
        @from = from
        @helo = helo
        @peer = peer
        @secure = secure
        @to = []
        @data = +""
      end

      # @attribute [String] The envelope sender.
      attr_reader :from

      # @attribute [Array(String)] The envelope recipients, in the order given.
      attr_reader :to

      # @attribute [String] The message as it arrived, headers and all.
      attr_reader :data

      # @attribute [String | Nil] The domain the client introduced itself as.
      attr_reader :helo

      # @attribute [String | Nil] Where the client connected from.
      attr_reader :peer

      # @returns [Boolean] Whether the message arrived over TLS.
      def secure? = @secure

      # The headers, unfolded and downcased.
      # @returns [Hash(String, String)]
      def headers = @headers ||= parse_headers

      # @returns [String | Nil]
      def subject = headers["subject"]

      # Everything after the blank line that ends the headers. A message with
      # no blank line in it is all headers and no body (RFC 5322 2.1), which
      # is also what a truncated one looks like.
      #
      # @returns [String]
      def body = split_at_blank_line[1].to_s

      # @returns [Integer] The size of the message, in bytes.
      def bytesize = data.bytesize

      # Enables `in [from, [to, *]]`
      def deconstruct = [from, to]

      # Enables `in {to: [/@example\.test\z/, *], subject: /urgent/i}`
      def deconstruct_keys(_keys) = { from:, to:, data:, helo:, peer:, headers:, subject:, body: }

      def inspect = "#<#{self.class} from=#{from.inspect} to=#{to.inspect} #{bytesize}B>"

      private

        # RFC 5322 2.2.3: a header field continues onto any following line
        # that starts with whitespace, so unfold those before splitting each
        # on its first colon. Last value wins for a repeated field — #data is
        # right there for anything that needs more than that.
        def parse_headers
          split_at_blank_line.first.to_s.gsub(/\r?\n[ \t]+/, " ").lines.filter_map do |line|
            case line.split(":", 2)
            in [name, value] then [name.strip.downcase, value.strip]
            else nil
            end
          end.to_h
        end

        def split_at_blank_line = data.split(/\r?\n\r?\n/, 2)
    end
  end
end
