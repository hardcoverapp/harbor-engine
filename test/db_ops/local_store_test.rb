require "test_helper"

class HarborDbOpsLocalStoreTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("harbor-local-store")
    @store = Harbor::DbOps::LocalStore.new(root: @root)
  end

  teardown { FileUtils.remove_entry(@root) if @root && File.exist?(@root) }

  test "a dump directory's digest covers every file name and its contents" do
    dir = File.join(@root, "shop/cleaned/1700000000000")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "toc.dat"), "toc")
    File.write(File.join(dir, "1.dat.gz"), "data")
    original = Harbor::DbOps::LocalStore.digest(dir)
    assert_equal 7, Harbor::DbOps::LocalStore.size(dir)

    File.write(File.join(dir, "1.dat.gz"), "DATA")
    refute_equal original, Harbor::DbOps::LocalStore.digest(dir), "changed contents change the digest"
    File.write(File.join(dir, "1.dat.gz"), "data")
    assert_equal original, Harbor::DbOps::LocalStore.digest(dir)
    File.rename(File.join(dir, "1.dat.gz"), File.join(dir, "2.dat.gz"))
    refute_equal original, Harbor::DbOps::LocalStore.digest(dir), "renamed files change the digest"
  end

  test "single-file archives from older backups still digest" do
    path = File.join(@root, "old.dump")
    File.write(path, "dump")
    assert_equal Digest::SHA256.hexdigest("dump"), Harbor::DbOps::LocalStore.digest(path)
    assert_equal 4, Harbor::DbOps::LocalStore.size(path)
  end

  test "paths cannot escape the backup root" do
    assert_raises(Harbor::DbOps::LocalStore::Error) { @store.absolute("../elsewhere") }
    assert_raises(Harbor::DbOps::LocalStore::Error) { @store.absolute("/etc/passwd") }
    assert_equal File.join(File.expand_path(@root), "shop/full"), @store.absolute("shop/full")
  end
end
