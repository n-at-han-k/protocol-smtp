# frozen_string_literal: true

require "protocol/smtp/reply"

describe Protocol::SMTP::Reply do
  with "a single line" do
    let(:reply) {subject.new(250, "Ok")}

    it "puts the code and the text on one line" do
      expect(reply.to_s).to be == "250 Ok"
    end

    it "is positive" do
      expect(reply).to be(:positive?)
      expect(reply).not.to be(:transient?)
      expect(reply).not.to be(:permanent?)
    end
  end

  with "several lines" do
    let(:reply) {subject.new(250, ["greets you", "SIZE 100", "8BITMIME"])}

    it "joins every line but the last to its code with a hyphen" do
      expect(reply.to_s).to be == "250-greets you\r\n250-SIZE 100\r\n250 8BITMIME"
    end
  end

  with "no text at all" do
    let(:reply) {subject.new(220, nil)}

    it "still produces a valid line" do
      expect(reply.to_s).to be == "220 "
    end
  end

  it "classifies 4xx as transient and 5xx as permanent" do
    expect(subject.new(451, "Try later")).to be(:transient?)
    expect(subject.new(550, "No")).to be(:permanent?)
    expect(subject.new(550, "No")).not.to be(:positive?)
  end

  it "compares by code and lines" do
    expect(subject.ok).to be == subject.new(250, "Ok")
    expect(subject.ok).not.to be == subject.new(250, "Fine")
    expect({subject.ok => true}[subject.new(250, "Ok")]).to be == true
  end

  it "deconstructs for pattern matching" do
    case subject.rejected("Spam")
    in {code: 500.., lines: [text]}
      expect(text).to be == "Spam"
    end
  end
end
