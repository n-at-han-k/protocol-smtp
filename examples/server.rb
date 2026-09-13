#!/usr/bin/env ruby
# frozen_string_literal: true

# A one-connection-at-a-time SMTP server over a plain socket, to show that
# the state machine needs nothing but a stream. async-smtp is the version
# that serves more than one client at once.
#
# Test with: swaks --to you@example.com --server localhost:2525

require "socket"
require_relative "../lib/protocol/smtp"

Addrinfo.tcp("127.0.0.1", 2525).listen do |server|
  loop do
    peer, address = server.accept

    Protocol::SMTP::Server.new(peer, domain: "example.test", peer: address.ip_address).each do |message|
      puts "#{message.from} -> #{message.to.join(", ")} (#{message.bytesize} bytes): #{message.subject}"

      Protocol::SMTP::Reply.ok("Queued")
    end
  end
end
