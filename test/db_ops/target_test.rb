require "test_helper"

# Target is the guard rail in front of a DROP SCHEMA. These tests are the
# specification for "when may a staging restore destroy this database".
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

  def test_staging_is_destroyable
    assert stage.assert_safe_to_destroy!(protected_target: prod)
  end

  def test_it_refuses_to_destroy_the_protected_database
    err = assert_raises(Harbor::DbOps::Target::Error) do
      prod.assert_safe_to_destroy!(protected_target: prod)
    end
    assert_match(/refusing to destroy/, err.message)
    assert_match(/same server\+database/, err.message)
  end

  # The nightmare: STAGING_DATABASE_URL pasted with production's details. It
  # names no "staging" anywhere, so both guards fire.
  def test_it_refuses_a_database_that_does_not_name_itself_staging
    other = Harbor::DbOps::Target.new("postgresql://u:p@some-host.example.com:5432/shop_production")
    err = assert_raises(Harbor::DbOps::Target::Error) do
      other.assert_safe_to_destroy!(protected_target: prod)
    end
    assert_match(/does not look like a disposable environment/, err.message)
  end

  # Same server+db as production must stay refused even with the override on —
  # the override is only for "this really is disposable, it's just named oddly".
  def test_the_override_cannot_unlock_the_protected_database
    with_env("TEST_ALLOW_UNSAFE_RESTORE" => "true") do
      assert_raises(Harbor::DbOps::Target::Error) do
        prod.assert_safe_to_destroy!(protected_target: prod)
      end
    end
  end

  def test_the_override_allows_an_oddly_named_disposable_database
    other = Harbor::DbOps::Target.new("postgresql://u:p@qa-box.example.com:5432/scratch")
    assert_raises(Harbor::DbOps::Target::Error) { other.assert_safe_to_destroy!(protected_target: prod) }
    with_env("TEST_ALLOW_UNSAFE_RESTORE" => "true") do
      assert other.assert_safe_to_destroy!(protected_target: prod)
    end
  end

  def test_staging_in_the_host_alone_is_enough
    t = Harbor::DbOps::Target.new("postgresql://u:p@staging-db.example.com:5432/shop")
    assert t.assert_safe_to_destroy!(protected_target: prod)
  end

  def test_same_server_but_a_different_database_is_not_the_protected_one
    sibling = Harbor::DbOps::Target.new(
      "postgresql://dbadmin:x@production-db-follower-1.db.example.com:25060/shop_staging"
    )
    refute sibling.same_server_and_db?(prod)
    assert sibling.assert_safe_to_destroy!(protected_target: prod)
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
