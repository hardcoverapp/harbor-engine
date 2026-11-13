require "test_helper"

class HarborDbOpsGreenmaskTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  test "connection strings carry no password and quote awkward values" do
    target = Harbor::DbOps::Target.new("postgres://backup:s3cret@follower.example:25060/shop?sslmode=require")
    conninfo = Harbor::DbOps::Greenmask.conninfo(target)
    assert_equal "host=follower.example port=25060 user=backup dbname=shop sslmode=require", conninfo
    assert_not_includes conninfo, "s3cret"
    assert_equal "'it\\'s here'", Harbor::DbOps::Greenmask.quote("it's here")
  end

  test "rules are the host's files: <database>.yml for cleaned, staging/<database>.yml for staging" do
    assert_equal File.join(RULES, "shop.yml"), Harbor::DbOps::Greenmask.rules_path("shop").to_s
    assert_equal File.join(RULES, "staging/shop.yml"), Harbor::DbOps::Greenmask.rules_path("shop", "staging").to_s
    assert Harbor::DbOps::Greenmask.rules?("shop", "staging")
    assert_not Harbor::DbOps::Greenmask.rules?("shop_cache", "staging")
    assert_equal [ "public.audit_log" ], Harbor::DbOps::Greenmask.rules("shop").dig("pg_dump_options", "exclude-table-data")
    assert_raises(Harbor::DbOps::Greenmask::Error) { Harbor::DbOps::Greenmask.rules("ledger") }
  end

  test "the rules folder is the host's to name, and defaults to config/greenmask in the app" do
    Harbor.config.masking_rules_path = -> { "/srv/rules" }
    assert_equal "/srv/rules/staging/shop.yml", Harbor::DbOps::Greenmask.rules_path("shop", "staging").to_s
    Harbor.config.masking_rules_path = Harbor::Configuration.new.masking_rules_path
    assert_equal Rails.root.join("config/greenmask/shop.yml"), Harbor::DbOps::Greenmask.rules_path("shop")
    assert_equal "config/greenmask/shop.yml", Harbor::DbOps::Greenmask.relative(Harbor::DbOps::Greenmask.rules_path("shop")).to_s
  end

  test "the generated config points greenmask at storage, the pg binaries and the rules" do
    Harbor.config.greenmask_pg_bin_path = "/opt/pg/bin"
    config = Harbor::DbOps::Greenmask.config(storage: Harbor::DbOps::Greenmask.directory_storage("/backups/shop/cleaned"), tmp_dir: "/tmp/x",
                                             dump: { "transformation" => [] })
    assert_equal({ "type" => "directory", "directory" => { "path" => "/backups/shop/cleaned" } }, config["storage"])
    assert_equal "/tmp/x", config.dig("common", "tmp_dir")
    assert_equal "/opt/pg/bin", config.dig("common", "pg_bin_path")
    assert_equal({ "transformation" => [] }, config["dump"])
  end

  test "with no folder named, the pg binaries are wherever pg_dump is on the PATH" do
    dir = Dir.mktmpdir
    File.write(File.join(dir, "pg_dump"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(dir, "pg_dump"))
    ENV["PATH"] = dir
    assert_equal dir, Harbor::DbOps::Greenmask.pg_bin_path
    ENV["PATH"] = "/nonexistent"
    assert_raises(Harbor::DbOps::Greenmask::Error) { Harbor::DbOps::Greenmask.pg_bin_path }
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "a missing greenmask is reported by name, and only when a dump is asked for" do
    Harbor.config.greenmask_bin = "/nonexistent/greenmask"
    Harbor.config.greenmask_pg_bin_path = "/opt/pg/bin"
    dir = Dir.mktmpdir
    error = assert_raises(Harbor::DbOps::Greenmask::Error) do
      Harbor::DbOps::Greenmask.prune(storage: Harbor::DbOps::Greenmask.directory_storage(dir), tmp_dir: dir, keep: 2)
    end
    assert_match "greenmask is not installed (looked for /nonexistent/greenmask)", error.message
    assert_empty Dir.children(dir), "the generated config is removed"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "the progress watcher reports the size of the dump being written" do
    dir = Dir.mktmpdir
    seen = Queue.new
    watcher = Harbor::DbOps::Greenmask.watch(dir, [], ->(bytes) { seen << bytes }, nil, interval: 0.05)
    assert_equal 0, seen.pop, "nothing written yet"
    FileUtils.mkdir_p(File.join(dir, "1700000000000"))
    File.write(File.join(dir, "1700000000000", "1.dat.gz"), "x" * 10)
    Timeout.timeout(5) { loop { break if seen.pop == 10 } }
  ensure
    watcher&.kill
    FileUtils.remove_entry(dir) if dir
  end

  test "pruning refuses to delete every dump" do
    assert_raises(Harbor::DbOps::Greenmask::Error) do
      Harbor::DbOps::Greenmask.prune(storage: Harbor::DbOps::Greenmask.directory_storage("/x"), tmp_dir: "/tmp", keep: 0)
    end
  end
end
