# frozen_string_literal: true

require "stringio"

# The stream the tests talk over: it reads what they scripted and keeps what
# was written back, so a whole conversation can be checked without a socket.
module Protocol
  module SMTP
    # A stream that reads what the test scripted and keeps what was written
    # back, so a whole conversation can be checked without a socket.
    class Duplex
      def initialize(input = "")
        @input = StringIO.new(input)
        @output = +""
        @closed = false
      end

      attr_reader :output

      def closed? = @closed

      def gets(separator, limit = nil) = @input.gets(separator, limit)

      def write(string)
        @output << string
      end

      def flush = nil

      def close
        @closed = true
      end

      # What the server said, one line per reply line.
      def lines = @output.split("\r\n")

      # The reply codes it sent, in order — one per reply, not per line: a
      # continuation line carries a hyphen where the last one has a space.
      def codes
        lines.filter_map do |line|
          case line[3]
          when " ", nil then Integer(line[0, 3])
          end
        end
      end
    end
  end
end
