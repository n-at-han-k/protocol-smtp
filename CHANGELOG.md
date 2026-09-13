# Changelog

All notable changes to protocol-smtp are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-09-13

### Added

- `Protocol::SMTP::Server`: RFC 5321's command/reply state machine, as
  `#write_greeting` / `#read_message` / `#write_reply` primitives. It answers
  every command the protocol owns — sequencing (4.3.2), a re-issued
  `MAIL FROM` starting the transaction over (4.1.1.2), dot unstuffing (4.5.2),
  the line length limit (4.5.3.1) and a message size limit, which it enforces
  at the terminating dot rather than mid-body (RFC 1870 6.2). The loop, the
  application and the stream's lifetime belong to the caller.
- `Protocol::SMTP::Client`: the commands, multi-line reply parsing, `EHLO`
  extension parsing with a `HELO` fallback (2.2.1), dot stuffing, and
  `#transaction` / `#deliver` for a whole transaction.
- Client-side `STARTTLS` (RFC 3207) and `AUTH PLAIN` / `LOGIN` (RFC 4616);
  server-side `STARTTLS`, advertised only when an upgrade is possible.
- `Protocol::SMTP::Message` with the envelope kept separate from the unfolded
  headers, and pattern matching over both.
- `Protocol::SMTP::Reply`, including multi-line replies, and stripping CRLF
  from reply text so quoting a client back at itself cannot inject a reply.
- `Protocol::SMTP::Connection`: the line plumbing both roles share, over any
  stream that answers `#gets`, `#write`, `#flush` and `#close`.
