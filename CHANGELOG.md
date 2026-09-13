# Changelog

## 0.1.0

- The server state machine (`Protocol::SMTP::Server`): RFC 5321 sequencing,
  dot unstuffing, line length and message size limits.
- The client (`Protocol::SMTP::Client`): commands, multi-line reply parsing,
  dot stuffing, and `#deliver` for a whole transaction.
- `Protocol::SMTP::Message` with envelope, unfolded headers, and pattern
  matching.
- `Protocol::SMTP::Reply`, including multi-line replies.
- Client-side `STARTTLS` (RFC 3207) and `AUTH PLAIN`/`LOGIN` (RFC 4616),
  `EHLO` extension parsing, and a `HELO` fallback.
- Server-side `STARTTLS`, advertised only when an upgrade is possible.
