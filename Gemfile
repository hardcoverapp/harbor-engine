source "https://rubygems.org"

gemspec

# The dummy app the tests run against (test/dummy).
gem "pg", "~> 1.1"

group :development, :test do
  gem "rubocop-rails-omakase", require: false
end

# The slot ledger's tests talk to a real Redis (REDIS_URL).
gem "redis-client"

# Database backups copy dumps to S3-compatible buckets (Harbor::DbOps::BackupBucket).
# A host adds this gem only if it uses one, so it is not a dependency of Harbor's,
# and it is loaded only when a bucket is used: the tests that need it require it.
gem "aws-sdk-s3", "~> 1.170", require: false
