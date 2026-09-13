# frozen_string_literal: true

module Protocol
  module SMTP
    # The base class for every error this gem raises.
    class Error < StandardError; end

    # The peer sent a line longer than the protocol allows, which means it is
    # not going to stop on its own — the connection is done.
    class LineLengthError < Error; end

    # The peer went away mid-conversation.
    class ClosedError < Error; end

    # The peer sent something that is not a reply at all.
    class InvalidReplyError < Error; end

    # The server answered with a code the client cannot continue from.
    class ReplyError < Error
      # @parameter reply [Reply] The reply that ended the transaction.
      def initialize(reply)
        @reply = reply
        super("Unexpected reply: #{reply}")
      end

      # @attribute [Reply] The reply that ended the transaction.
      attr_reader :reply
    end

    # The server offers no authentication mechanism this client implements.
    class AuthenticationError < Error; end
  end
end
