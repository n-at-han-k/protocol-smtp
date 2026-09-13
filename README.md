# protocol-smtp

Abstractions for the SMTP protocol: RFC 5321's command/reply state machine and
the RFC 5322 message it assembles, for both sides of the conversation.

No sockets, no concurrency, no dependencies. A `Connection` talks over anything
that answers `#gets(separator, limit)`, `#write`, `#flush` and `#close` — a
`TCPSocket`, an `IO::Stream`, a `StringIO`. Binding it to an endpoint and a
reactor is [async-smtp](../async-smtp)'s job, the way async-http binds
protocol-http.

## Server

```ruby
require "protocol/smtp"

Protocol::SMTP::Server.new(stream, domain: "mail.example.com").each do |message|
  message.from                 # "me@example.com" — the envelope
  message.to                   # ["you@example.com"]
  message.subject              # "Hello" — the headers, unfolded
  message.data                 # the whole of it, verbatim

  Protocol::SMTP::Reply.ok("queued")
end
```

`#each` greets the client, answers every command until it quits, and calls the
block with each complete message. The block returns the `Reply` the client is
given; `Reply.ok` and `Reply.rejected` cover the usual two.

The state machine enforces RFC 5321 4.3.2 sequencing (`MAIL` before `RCPT`
before `DATA`, a `503` otherwise), re-issued `MAIL FROM` starting the
transaction over (4.1.1.2), dot unstuffing (4.5.2), the line length limit
(4.5.3.1) and a message size limit.

What a framework lets *its* users return instead of a `Reply` — a String, a
status code, nothing at all — is that framework's business, not the protocol's.

## Client

```ruby
client = Protocol::SMTP::Client.new(stream)
client.deliver(
  from: "me@example.com",
  to: "you@example.com",
  body: "Subject: Hello\r\n\r\nHi.\r\n",
)
client.quit
```

Each command returns its `Reply` rather than raising on one, because which
codes are fatal depends on what you are doing. `#deliver`, which has to get a
whole transaction through in order, raises `ReplyError` on anything it cannot
continue from.

## Message

The envelope (`#from`, `#to`) is what the conversation said; the headers are
what the data claims. They disagree more often than people expect, so both are
there and neither is derived from the other.

A message pattern matches as `[from, to]`, or by keys — `from`, `to`, `data`,
`helo`, `peer`, `headers`, `subject`, `body`:

```ruby
case message
in { to: [/@example\.com\z/, *], subject: /urgent/i } then ...
end
```

## What it does not do

No STARTTLS, no AUTH, no pipelining, no relaying or queueing. It is the
conversation, not a mail system.

## License

MIT.
