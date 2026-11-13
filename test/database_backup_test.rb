require "test_helper"

class HarborDatabaseBackupTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  setup do
    @root = @backup_root
    @backup = Harbor::DatabaseBackup.create!(database_key: "shop", variant: "cleaned", path: "shop/cleaned/1700000000000",
                                     bytes: 1, sha256: "x", copies: { "local" => {} })
    FileUtils.mkdir_p(@backup.folder)
    File.write(File.join(@backup.folder, "toc.dat"), "toc")
  end
  test "locations list the drive first, checked live, then recorded bucket copies" do
    @backup.record_copy!("r2", bucket: "shop-db-cleaned", key: @backup.path)
    assert_equal({ "local" => true, "r2" => true }, @backup.locations)
    assert_equal %w[local r2], @backup.locations.keys
    FileUtils.rm_rf(@backup.folder)
    assert_equal({ "local" => false, "r2" => true }, @backup.locations)
  end

  test "forgetting the last copy removes the backup" do
    @backup.record_copy!("r2", bucket: "b", key: @backup.path)
    refute @backup.forget_copy!("r2")
    assert_equal %w[local], @backup.reload.copies.keys
    FileUtils.rm_rf(@backup.folder)
    assert @backup.forget_copy!("local")
    refute Harbor::DatabaseBackup.exists?(@backup.id)
  end

  test "location names read as providers" do
    assert_equal "Backup drive", Harbor::DatabaseBackup.location_label("local")
    assert_equal "Cloudflare R2", Harbor::DatabaseBackup.location_label("r2")
    assert_equal "Backblaze", Harbor::DatabaseBackup.location_label("backblaze")
  end
end
