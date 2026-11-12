source "https://rubygems.org"

gemspec

# The dummy app the tests run against (test/dummy).
gem "pg", "~> 1.1"

group :development, :test do
  gem "rubocop-rails-omakase", require: false
end

# The slot ledger's tests talk to a real Redis (REDIS_URL).
gem "redis-client"
