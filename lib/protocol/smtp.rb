# frozen_string_literal: true

require_relative "smtp/version"

require_relative "smtp/client"
require_relative "smtp/connection"
require_relative "smtp/error"
require_relative "smtp/message"
require_relative "smtp/reply"
require_relative "smtp/server"

# @namespace
module Protocol
  # Abstractions for the SMTP protocol: the command/reply state machine
  # (RFC 5321) and the message it assembles (RFC 5322), for both sides of the
  # conversation. No sockets, no concurrency, no dependencies — async-smtp
  # binds this to a real endpoint.
  #
  # @namespace
  module SMTP
  end
end
