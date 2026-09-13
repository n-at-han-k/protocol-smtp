# frozen_string_literal: true

require "protocol/smtp"

describe Protocol::SMTP do
  it "has a version number" do
    expect(Protocol::SMTP::VERSION).not.to be_nil
  end
end
