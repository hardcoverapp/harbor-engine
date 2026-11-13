require "test_helper"

class HarborDbOpsMysqlTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  test "mysql:// URLs parse with MySQL's port and TLS options, and logs hide the password" do
    target = Harbor::DbOps::Target.new("mysql://backup:s%23cr%3Bt@db.example.com/blog?ssl-mode=REQUIRED")
    assert target.mysql?
    assert_equal [ 3306, "s#cr;t", "blog" ], [ target.port, target.password, target.database ]
    assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Target.new("mysql://u:p@h/db?sslmode=require") }
    assert_equal "mysql://backup:<redacted>@db/x failed", Harbor::DbOps::Target.scrub("mysql://backup:s3cret@db/x failed")
  end

  test "the password goes in a private option file, quoted, never argv" do
    target = Harbor::DbOps::Target.new("mysql://backup:#{CGI.escape('pa"ss;#\\')}@db.example.com:25060/ledger?ssl-mode=REQUIRED")
    contents = mode = nil
    Harbor::DbOps::Mysql.with_option_file(target) do |path|
      contents = File.read(path)
      mode = File.stat(path).mode & 0o777
    end
    assert_equal 0o600, mode
    assert_includes contents, %(password="pa\\"ss;#\\\\")
    assert_includes contents, "port=25060"
    assert_includes contents, %(ssl-mode="REQUIRED")
    client, mysql = contents.split("[mysql]")
    refute_includes client, "connect-timeout", "mysqldump rejects connect-timeout in [client]"
    assert_includes mysql, "connect-timeout=15"
  end

  test "dump pipes mysqldump through gzip with a consistent, non-locking snapshot" do
    target = Harbor::DbOps::Target.new("mysql://backup:secret@db.example.com/blog")
    dir = Dir.mktmpdir
    script = nil
    run = ->(_env, shell, **) { script = shell; File.binwrite(File.join(dir, "blog.sql.gz"), "gz"); true }
    with_stub(Harbor::DbOps::Pg, :stream_shell!, run) do
      assert_equal File.join(dir, "blog.sql.gz"), Harbor::DbOps::Mysql.dump(target, dir:, database_key: "blog")
    end
    assert_match(/\Aset -o pipefail; 'mysqldump' '--defaults-extra-file=[^']+'/, script)
    %w[--single-transaction --quick --routines --triggers --no-tablespaces].each { |flag| assert_includes script, "'#{flag}'" }
    refute_includes script, "--databases", "dumps restore into a database of any name"
    refute_includes script, "secret"
    assert_match(/\| gzip -6 > /, script)
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
