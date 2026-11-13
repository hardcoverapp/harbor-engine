require "test_helper"

require "aws-sdk-s3"

class HarborDbOpsBackupBucketTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  setup do
    @dir = Dir.mktmpdir
    %w[heartbeat metadata.json toc.dat 2.dat.gz 1.dat.gz].each { |name| File.write(File.join(@dir, name), name) }
    @client = Aws::S3::Client.new(stub_responses: true)
    @bucket = Harbor::DbOps::BackupBucket.new(bucket: "dev-dumps", client: @client)
  end
  teardown { FileUtils.remove_entry(@dir) }

  test "uploads keep the dump's path, with metadata and heartbeat last" do
    @bucket.upload_dump(@dir, prefix: "shop/cleaned/1700000000000")
    keys = @client.api_requests.select { _1[:operation_name] == :put_object }.map { _1[:params][:key] }
    assert_equal %w[1.dat.gz 2.dat.gz toc.dat metadata.json heartbeat].map { "shop/cleaned/1700000000000/#{_1}" }, keys
  end

  test "retention keeps the newest dump ids and deletes everything under the rest" do
    ids = %w[1700000000001 1700000000002 1700000000003]
    @client.stub_responses(:list_objects_v2, lambda { |context|
      if context.params[:delimiter]
        { common_prefixes: ids.map { { prefix: "shop/cleaned/#{_1}/" } }, is_truncated: false }
      else
        { contents: [ { key: "#{context.params[:prefix]}toc.dat" }, { key: "#{context.params[:prefix]}1.dat.gz" } ], is_truncated: false }
      end
    })
    assert_equal %w[1700000000001], @bucket.prune("shop/cleaned", keep: 2)
    deleted = @client.api_requests.select { _1[:operation_name] == :delete_objects }.flat_map { _1[:params][:delete][:objects].map { |o| o[:key] } }
    assert_equal %w[shop/cleaned/1700000000001/toc.dat shop/cleaned/1700000000001/1.dat.gz], deleted
    assert_raises(Harbor::DbOps::BackupBucket::Error) { @bucket.prune("shop/cleaned", keep: 0) }
  end

  test "each kind has its own bucket, and a bucket without credentials is refused" do
    ENV["TEST_BACKUP_S3_CLEANED_BUCKET"] = "dev-dumps"
    assert_nil Harbor::DbOps::BackupBucket.for("full")
    assert_nil Harbor::DbOps::BackupBucket.for("staging")
    error = assert_raises(Harbor::DbOps::BackupBucket::Error) { Harbor::DbOps::BackupBucket.for("cleaned") }
    assert_equal "TEST_BACKUP_S3_CLEANED_BUCKET is set but TEST_BACKUP_S3_ENDPOINT, TEST_BACKUP_S3_ACCESS_KEY_ID, " \
                 "TEST_BACKUP_S3_SECRET_ACCESS_KEY is not", error.message
    ENV["TEST_BACKUP_S3_ENDPOINT"] = "https://account.r2.cloudflarestorage.com"
    ENV["TEST_BACKUP_S3_ACCESS_KEY_ID"] = "id"
    ENV["TEST_BACKUP_S3_SECRET_ACCESS_KEY"] = "secret"
    assert_equal "dev-dumps", Harbor::DbOps::BackupBucket.for("cleaned").bucket
  end

  test "staging dumps share the private full bucket, never the cleaned one" do
    ENV["TEST_BACKUP_S3_CLEANED_BUCKET"] = "dev-dumps"
    ENV["TEST_BACKUP_S3_FULL_BUCKET"] = "private-dumps"
    assert_equal %w[dev-dumps private-dumps private-dumps], %w[cleaned full staging].map { Harbor::DbOps::BackupBucket.bucket_for(_1) }
  end

  test "the host names the prefix of the bucket's ENV keys" do
    Harbor.config.backup_bucket_env_prefix = "SITE_DUMPS"
    assert_equal "SITE_DUMPS_CLEANED_BUCKET", Harbor::DbOps::BackupBucket.bucket_env("cleaned")
    assert_equal %w[SITE_DUMPS_ENDPOINT SITE_DUMPS_ACCESS_KEY_ID SITE_DUMPS_SECRET_ACCESS_KEY], Harbor::DbOps::BackupBucket.credential_env
  end

  test "uploads use the upload threads setting" do
    Harbor::Setting.set!(:database_upload_threads, "9")
    seen = []
    manager = Object.new
    manager.define_singleton_method(:upload_file) { |_path, **options| seen << options[:thread_count] }
    with_stub(Aws::S3::TransferManager, :new, manager) { @bucket.upload_dump(@dir, prefix: "shop/full/1700000000000") }
    assert_equal [ 9 ], seen.uniq
  end

  test "the location name comes from the endpoint unless set" do
        { "https://acct.r2.cloudflarestorage.com" => "r2", "https://nyc3.digitaloceanspaces.com" => "spaces",
      "https://storage.googleapis.com" => "gcs", "https://s3.us-east-1.amazonaws.com" => "s3" }.each do |endpoint, name|
      ENV["TEST_BACKUP_S3_ENDPOINT"] = endpoint
      assert_equal name, Harbor::DbOps::BackupBucket.location
    end
    ENV["TEST_BACKUP_S3_LOCATION"] = "backblaze"
    assert_equal "backblaze", Harbor::DbOps::BackupBucket.location
  end
end
