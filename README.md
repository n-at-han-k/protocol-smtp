# protocol-smtp

Abstractions for the SMTP protocol: RFC 5321's command/reply state machine and
the RFC 5322 message it assembles, for both sides of the conversation.

No sockets and no concurrency, and the one dependency is a deprecation DSL. A
`Connection` talks over anything that answers `#gets(separator, limit)`,
`#write`, `#flush` and `#close` — a
`TCPSocket`, an `IO::Stream`, a `StringIO`. Binding it to an endpoint and a
reactor is [async-smtp](../async-smtp)'s job, the way async-http binds
protocol-http.

## Server

```ruby
require "protocol/smtp"

server = Protocol::SMTP::Server.new(stream, domain: "mail.example.com")
server.write_greeting

while message = server.read_message
  message.from                 # "me@example.com" — the envelope
  message.to                   # ["you@example.com"]
  message.subject              # "Hello" — the headers, unfolded
  message.data                 # the whole of it, verbatim

  server.write_reply(Protocol::SMTP::Reply.ok("queued"))
end
```

`#read_message` answers every command the state machine owns — `MAIL`, `RCPT`,
`RSET`, `NOOP`, `QUIT`, the 354 before `DATA` — and hands back each complete
message. The reply *to the message* is the one reply the protocol has no
opinion about, so it is yours to write.

Who drives that loop, what an application is allowed to answer with, and when
the stream gets closed are all deliberately absent: that is
[async-smtp](../async-smtp)'s job, for a socket on a reactor. Nothing here
opens, closes, or waits on anything.

The state machine enforces RFC 5321 4.3.2 sequencing (`MAIL` before `RCPT`
before `DATA`, a `503` otherwise), re-issued `MAIL FROM` starting the
transaction over (4.1.1.2), dot unstuffing (4.5.2), the line length limit
(4.5.3.1) and a message size limit. Past that size it keeps reading the body
and answers `552` at the terminating dot, rather than replying to the rest of
the message as if it were commands (RFC 1870 6.2).

`EHLO` advertises `SIZE`, `8BITMIME`, and `STARTTLS` when — and only when — an
upgrade is possible. Pass a callable that takes the current stream and returns
an encrypted one; the `220` goes out in the clear first, and the client has to
`EHLO` again afterwards (RFC 3207 4.2):

```ruby
Protocol::SMTP::Server.new(stream, starttls: ->(stream) {OpenSSL::SSL::SSLSocket.new(stream, context).tap(&:accept)})
```

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
continue from. `#quit` sends `QUIT` and reads the 221; closing the stream is
for whoever opened it.

`#hello` falls back to `HELO` for a server that does not know `EHLO`
(RFC 5321 2.2.1), and what `EHLO` advertised is available afterwards:

```ruby
client.hello("client.example.com")
client.extensions            # {"SIZE" => "35651584", "AUTH" => "PLAIN LOGIN", ...}
client.starttls?             # true — ask with #starttls, then replace client.stream
client.mechanisms            # ["PLAIN", "LOGIN"]
client.maximum_message_size  # 35651584

client.authenticate("user", "password")  # AUTH PLAIN (RFC 4616), or LOGIN
```

Upgrading the stream itself is the caller's job, because a protocol gem has no
socket to upgrade — that is [async-smtp](../async-smtp)'s `Client`.

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

No server-side `AUTH` (an `AUTH` command gets a `502`), no pipelining, no
`CHUNKING`, no relaying or queueing, no DKIM or SPF. It is the conversation,
not a mail system.

## Tests

They live in the `__END__` section of the file they test, and run with
[scampi](https://rubygems.org/gems/scampi):

``` shell
bin/test                            # everything
bin/test lib/protocol/smtp/server.rb # one file
```

## Releasing

Inside the devshell:

``` shell
bin/test                  # 1. green suite
gem kit bump minor        # 2. bump the version
gem kit changelog --write # 3. write the entry
git commit -am "Release ..." # 4. the bump and the entry, one commit
gem kit release           # 5. gates, build, push
gem kit tag --push        # 6. tag it
```

Steps 2 and 5 are gates: a deprecation due at the new version, or a missing
changelog section, stops them.

## License

MIT.
