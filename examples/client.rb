#!/usr/bin/env ruby
# frozen_string_literal: true

# Deliver one message over a plain socket. Run examples/server.rb first.

require "socket"
require_relative "../lib/protocol/smtp"

TCPSocket.open("127.0.0.1", 2525) do |socket|
  client = Protocol::SMTP::Client.new(socket)

  reply = client.deliver(
    from: "me@example.test",
    to: "you@example.test",
    body: "Subject: Hello\r\n\r\nSent by protocol-smtp.\r\n",
    domain: "client.example.test",
  )

  puts reply
  client.quit
end
