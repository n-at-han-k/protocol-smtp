# frozen_string_literal: true

require_relative "lib/protocol/smtp/version"

Gem::Specification.new do |spec|
  spec.name = "protocol-smtp"
  spec.version = Protocol::SMTP::VERSION
  spec.authors = ["Nathan K"]
  spec.email = ["nathankidd@hey.com"]

  spec.summary = "Provides abstractions to handle the SMTP protocol."

  spec.description = <<~DESC
    The SMTP command/reply state machine (RFC 5321) and the message it
    assembles (RFC 5322), over any stream. No sockets and no concurrency:
    async-smtp binds this to an endpoint, the way async-http binds
    protocol-http.
  DESC

  spec.homepage = "https://github.com/n-at-han-k/protocol-smtp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # The tests ride along in the __END__ sections of the files they test; Ruby
  # stops parsing there, so they never load for anyone who installs this.
  spec.files = Dir.glob(["lib/**/*.rb", "*.md", "LICENSE"], base: __dir__)
  spec.require_paths = ["lib"]

  # The deprecation DSL, and the only runtime dependency: declaring a
  # deprecation is runtime work, and gem_kit is tiny and dependency-free
  # itself, so a protocol gem stays a protocol gem. Nothing else here needs a
  # gem — no sockets, no concurrency, which is the point.
  spec.add_dependency "gem_kit", "~> 0.2"

  spec.add_development_dependency "lefthook", "~> 2.1"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.60"
  spec.add_development_dependency "scampi", "~> 1.0"
  # The release toolchain: `gem kit bump|changelog|deprecations|release|tag`.
  spec.add_development_dependency "gem_kit-release", "~> 0.3"
end
