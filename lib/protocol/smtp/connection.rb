# frozen_string_literal: true

require_relative "error"

module Protocol
  module SMTP
    # The line plumbing both sides share: read a line, write a line, know when
    # the conversation is over. Works over any stream that answers
    # #gets(separator, limit), #write, #flush and #close — an IO, an
    # IO::Stream, a StringIO. No sockets and no concurrency live here; that is
    # async-smtp's half.
    class Connection
      CRLF = "\r\n"
      LF = "\n"

      # RFC 5321 4.5.3.1.4 and 4.5.3.1.6: 512 octets for a command line and
      # 1000 for a data line, both counting the CRLF. The larger covers both,
      # and is counted the way the RFC counts it — terminator included.
      DEFAULT_MAXIMUM_LINE_LENGTH = 1000

      # @parameter stream [IO | IO::Stream::Buffered | StringIO] The stream to talk over.
      # @parameter maximum_line_length [Integer] Refuse a line longer than this.
      def initialize(stream, maximum_line_length: DEFAULT_MAXIMUM_LINE_LENGTH)
        @stream = stream
        @maximum_line_length = maximum_line_length
        @open = true
      end

      # @attribute [IO | IO::Stream::Buffered | StringIO] The stream in use. It
      #   is replaced in place by a TLS upgrade (RFC 3207), which is why it is
      #   writable: the conversation continues over the new stream.
      attr_accessor :stream

      # @attribute [Integer] The longest line this connection will read.
      attr_reader :maximum_line_length

      # @returns [Boolean] Whether the conversation is over.
      def closed? = !@open

      # Stop reading after the line in hand, without touching the stream yet:
      # QUIT still has a 221 to write before the socket can go.
      def shutdown
        @open = false
      end

      # Finish the conversation and close the underlying stream.
      def close
        shutdown
        @stream.close
      end

      # Every line is CRLF-terminated per the RFC, but reading to the LF and
      # chomping takes either, so a peer that forgets the CR is still served
      # rather than left hanging.
      #
      # @returns [String | Nil] The line, without its terminator, or nil at the
      #   end of the stream.
      # @raises [LineLengthError] If the peer sent a line past the limit.
      # @raises [ClosedError] If the peer went away mid-line.
      def read_line
        # gets stops at the limit whether or not the separator turned up, so a
        # line that reached the limit without one is over-long by definition.
        @stream.gets(LF, @maximum_line_length).then do |line|
          case line
          when nil then nil
          else complete(line)
          end
        end
      end

      # @parameter line [String] The line to write, without its terminator.
      def write_line(line)
        @stream.write("#{line}#{CRLF}")
        @stream.flush
      end

      private

        # A line that came back without its terminator either ran past the
        # limit or the peer went away mid-line; those are different failures.
        def complete(line)
          case
          when line.end_with?(LF) then line.chomp
          when line.bytesize >= @maximum_line_length
            raise LineLengthError, "Line longer than #{@maximum_line_length} bytes!"
          else
            raise ClosedError, "Connection closed mid-line!"
          end
        end
    end
  end
end

__END__

require "duplex"

# A connection over a scripted stream, with a small limit so the length rules
# are testable without thousand-byte lines.
open_connection = lambda do |input, limit: 32|
  stream = Protocol::SMTP::Duplex.new(input)

  [Protocol::SMTP::Connection.new(stream, maximum_line_length: limit), stream]
end

describe "protocol/smtp/connection" do
  it "reads a line without its terminator, CRLF or bare LF" do
    open_connection.call("HELO example.com\r\n").first.read_line.should == "HELO example.com"

    # A peer that forgets the CR is served rather than left hanging:
    open_connection.call("NOOP\n").first.read_line.should == "NOOP"

    # And the end of the stream is not a line at all:
    open_connection.call("").first.read_line.should.be.nil
  end

  it "counts the line length limit the way RFC 5321 4.5.3.1 does, terminator included" do
    open_connection.call("#{"x" * 30}\r\n").first.read_line.should == "x" * 30

    lambda do
      open_connection.call("#{"x" * 31}\r\n").first.read_line
    end.should.raise(Protocol::SMTP::LineLengthError)
  end

  it "tells an over-long line apart from a peer that went away mid-line" do
    lambda do
      open_connection.call("NOOP").first.read_line
    end.should.raise(Protocol::SMTP::ClosedError)
  end

  it "writes lines with CRLF" do
    connection, stream = open_connection.call("")
    connection.write_line("250 Ok")

    stream.output.should == "250 Ok\r\n"
  end

  it "shuts the conversation down without touching the stream" do
    # QUIT still has a 221 to write before the socket can go:
    connection, stream = open_connection.call("")
    connection.shutdown

    connection.should.be.closed
    stream.should.not.be.closed
  end

  it "closes the stream when asked to" do
    connection, stream = open_connection.call("")
    connection.close

    stream.should.be.closed
  end
end
