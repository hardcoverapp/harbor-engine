require "test_helper"

# Target is the guard rail in front of a DROP SCHEMA. These tests are the
# specification for "is this target really that protected database".
class HarborDbOpsTargetTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  PROD = "postgresql://dbadmin:sekret@production-db-follower-1.db.example.com:25060/shop_production?sslmode=require".freeze
  STAGE = "postgresql://staging_app:pw@staging-db.db.example.com:25060/shop_staging?sslmode=require".freeze

  def prod  = Harbor::DbOps::Target.new(PROD, label: "production follower")
  def stage = Harbor::DbOps::Target.new(STAGE, label: "staging")

  # --- parsing ---

  def test_it_parses_the_parts
    t = prod
    assert_equal "production-db-follower-1.db.example.com", t.host
    assert_equal 25060, t.port
    assert_equal "dbadmin", t.user
    assert_equal "sekret", t.password
    assert_equal "shop_production", t.database
    assert_equal "require", t.params["sslmode"]
  end

  def test_it_rejects_a_non_postgres_or_mysql_url
    assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Target.new("sqlserver://u:p@h/db") }
    assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Target.new("") }
    assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Target.new(nil) }
  end

  def test_percent_encoded_credentials_are_decoded
    t = Harbor::DbOps::Target.new("postgresql://user%40corp:p%40ss%3Aword@h:5432/db")
    assert_equal "user@corp", t.user
    assert_equal "p@ss:word", t.password
  end

  # --- password containment ---

  def test_the_password_never_appears_in_anything_loggable
    t = prod
    [ t.redacted, t.to_s, t.inspect, t.url_without_password ].each do |s|
      refute_includes s, "sekret", "password leaked into #{s.inspect}"
    end
  end

  def test_url_without_password_is_still_a_usable_conninfo
    u = URI.parse(prod.url_without_password)
    assert_nil u.password
    assert_equal "dbadmin", u.user
    assert_equal "shop_production", u.path.delete_prefix("/")
    assert_equal "sslmode=require", u.query
  end

  def test_scrub_redacts_passwords_in_arbitrary_log_text
    line = "pg_dump: error: connection to #{PROD} failed"
    scrubbed = Harbor::DbOps::Target.scrub(line)
    refute_includes scrubbed, "sekret"
    assert_includes scrubbed, "<redacted>"
  end

  def test_pgpass_line_escapes_colons_and_backslashes
    t = Harbor::DbOps::Target.new("postgresql://u:pa%3Ass@h:5432/db")
    # The colon inside the password must be escaped, or libpq reads the line
    # as the wrong number of fields and silently finds no password.
    assert_equal "h:5432:db:u:pa\\:ss", t.pgpass_line
  end

  # --- the destroy guard ---

  def test_another_database_is_distinct_from_the_protected_one
    assert stage.assert_distinct_from!(prod)
  end

  def test_it_refuses_to_destroy_the_protected_database
    err = assert_raises(Harbor::DbOps::Target::Error) { prod.assert_distinct_from!(prod) }
    assert_match(/refusing to destroy/, err.message)
    assert_match(/same server\+database/, err.message)
  end

  # What a database is called is no evidence either way: only being the
  # protected database gets a target refused here.
  def test_names_are_never_looked_at
    plain = Harbor::DbOps::Target.new("postgresql://u:p@some-host.example.com:5432/shop_production")
    assert plain.assert_distinct_from!(prod)
    assert_not Harbor::DbOps::Target.method_defined?(:looks_disposable?)
  end

  # One database written several ways is still one database.
  def test_the_same_database_is_recognised_however_its_url_is_written
    base = "production-db-follower-1.db.example.com"
    same = [ "postgres://other:pw@#{base.upcase}:25060/SHOP_Production", "postgresql://x@#{base}.:25060/sh%6Fp_production?sslmode=require" ]
    same.each do |url|
      target = Harbor::DbOps::Target.new(url)
      assert target.same_server_and_db?(prod), url
      assert_raises(Harbor::DbOps::Target::Error, url) { target.assert_distinct_from!(prod) }
    end
    default_port = Harbor::DbOps::Target.new("postgres://a@db.example/shop")
    assert default_port.same_server_and_db?(Harbor::DbOps::Target.new("postgres://b:pw@db.example:5432/shop"))
    assert_not default_port.same_server_and_db?(Harbor::DbOps::Target.new("postgres://b:pw@db.example:5433/shop"))
    assert_not default_port.same_server_and_db?(Harbor::DbOps::Target.new("mysql://b:pw@db.example/shop")), "MySQL's default port is another server"
    local = Harbor::DbOps::Target.new("postgres://a@localhost/shop")
    assert local.same_server_and_db?(Harbor::DbOps::Target.new("postgres://a@127.0.0.1:5432/shop"))
    # A trailing slash or a second path segment is not a database URL at all.
    assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Target.new("postgres://a@db.example/shop/") }
  end

  def test_same_server_but_a_different_database_is_not_the_protected_one
    sibling = Harbor::DbOps::Target.new(
      "postgresql://dbadmin:x@production-db-follower-1.db.example.com:25060/shop_staging"
    )
    refute sibling.same_server_and_db?(prod)
    assert sibling.assert_distinct_from!(prod)
  end

  private

  def with_env(vars)
    previous = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end
end
