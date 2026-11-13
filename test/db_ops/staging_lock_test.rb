require "test_helper"

class HarborDbOpsStagingLockTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  setup do
    @previous = ENV.to_h
    @target = Harbor::DbOps::Target.new("postgres://dbadmin:secret@staging/shop?application_name=custom")
    @commands = []
  end

  test "the role in the staging URL is locked and only restore processes override read-only" do
    with_commands do
      Harbor::DbOps::StagingLock.with_lock(@target, logger: nil) do |target, env|
        assert_equal "dbadmin", target.user
        assert_equal "harbor-restorer", target.params["application_name"]
        assert_equal "-c default_transaction_read_only=off", env["PGOPTIONS"]
        assert_equal @previous.slice("PGOPTIONS"), ENV.to_h.slice("PGOPTIONS"), "unrelated worker threads must not receive the write override"
        @commands << :restore
      end
    end
    assert_match 'ALTER ROLE "dbadmin" SET default_transaction_read_only = on', @commands[0][:sql]
    assert_equal :restore, @commands[2]
    assert_match 'ALTER ROLE "dbadmin" RESET default_transaction_read_only', @commands[3][:sql]
    @commands.grep(Hash).each do |command|
      assert_equal "harbor-restorer", command[:target].params["application_name"]
      assert_equal "-c default_transaction_read_only=off", command[:env]["PGOPTIONS"]
    end
    assert_includes @commands[1][:sql], "application_name NOT IN ('harbor-restorer')"
  end

  test "a host names the restore's application and the applications a drain spares" do
    Harbor.config.restore_application_name = "site-restorer"
    Harbor.config.restore_spared_applications = %w[restorer o'brien]
    with_commands do
      Harbor::DbOps::StagingLock.with_lock(@target, logger: nil) do |target, _env|
        assert_equal "site-restorer", target.params["application_name"]
      end
    end
    assert_includes @commands[1][:sql], "application_name NOT IN ('restorer', 'o''brien', 'site-restorer')"
    assert_equal 2, @commands[1][:sql].scan("application_name NOT IN ('restorer', 'o''brien', 'site-restorer')").size, "the wait and the check spare the same connections"
  end

  test "an already locked role fails without restoring or unlocking another run" do
    with_commands(read_only: true) do
      error = assert_raises(Harbor::DbOps::Pg::Error) do
        Harbor::DbOps::StagingLock.with_lock(@target, logger: nil) { flunk "another restore owns the role" }
      end
      assert_match "already read-only", error.message
    end
    assert_empty @commands
  end

  test "a failed lock is never unlocked by this run" do
    with_stub(Harbor::DbOps::Pg, :capture!, "f") do
      with_stub(Harbor::DbOps::Pg, :exec_sql, ->(_target, sql, **) { @commands << sql; raise Harbor::DbOps::Pg::Error, "permission denied" }) do
        assert_raises(Harbor::DbOps::Pg::Error) do
          Harbor::DbOps::StagingLock.with_lock(@target, logger: nil) { flunk "lock failed" }
        end
      end
    end
    assert_equal 1, @commands.size
    refute_includes @commands.first, "RESET"
  end

  test "cleanup failure still resets the role and drains stale app connections" do
    Harbor.config.staging_lock_role = -> { "shop_app" }
    with_commands do
      assert_raises(Harbor::DbOps::Pg::Error) do
        Harbor::DbOps::StagingLock.with_lock(@target, logger: nil) { raise Harbor::DbOps::Pg::Error, "cleanup failed" }
      end
    end
    assert_match 'ALTER ROLE "shop_app" RESET default_transaction_read_only', @commands[2][:sql]
    assert_match "pg_terminate_backend", @commands[3][:sql]
  end

  test "failure to unlock is retried and reported" do
    with_stub(Harbor::DbOps::Pg, :capture!, "f") do
      with_stub(Harbor::DbOps::Pg, :exec_sql, ->(_target, sql, **) { @commands << sql; raise Harbor::DbOps::Pg::Error, "connection lost" if sql.include?(" RESET ") }) do
        error = assert_raises(Harbor::DbOps::Pg::Error) { Harbor::DbOps::StagingLock.with_lock(@target, logger: nil) { } }
        assert_match "Could not unlock", error.message
      end
    end
    assert_equal 3, @commands.count { |sql| sql.include?(" RESET ") }
  end

  test "write overrides reach pg_restore and psql without changing process ENV" do
    env = { "PGOPTIONS" => "-c default_transaction_read_only=off" }
    commands = []
    capture = ->(child_env, args, **) { commands << [ child_env, args ]; true }
    with_stub(Harbor::DbOps::Pg, :stream_cmd!, capture) do
      Harbor::DbOps::Pg.restore_file(@target, "/unused.dump", env:)
      Harbor::DbOps::Pg.reset_schemas(@target, env:)
      Harbor::DbOps::Pg.exec_file(@target, File.expand_path("../fixtures/files/sample.sql", __dir__), env:)
    end
    assert_equal %w[pg_restore psql psql], commands.map { |_, args| args.first }
    commands.each do |child_env, args|
      assert_equal env["PGOPTIONS"], child_env["PGOPTIONS"]
      refute args.any? { |arg| arg.to_s.include?("secret") }, "credentials must stay out of argv"
    end
    assert_equal @previous.slice("PGOPTIONS"), ENV.to_h.slice("PGOPTIONS")
  end

  private

  def with_commands(read_only: false, &block)
    capture = ->(target, sql, **options) { @commands << { target:, sql:, env: options[:env] }; true }
    with_stub(Harbor::DbOps::Pg, :capture!, read_only ? "t" : "f") do
      with_stub(Harbor::DbOps::Pg, :exec_sql, capture, &block)
    end
  end
end
