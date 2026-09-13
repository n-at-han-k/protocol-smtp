# frozen_string_literal: true

task :test do
  sh "bundle", "exec", "sus"
end

task :lint do
  sh "bundle", "exec", "rubocop"
end

task default: [:test, :lint]
