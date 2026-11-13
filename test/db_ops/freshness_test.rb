require "test_helper"

# Regression cover for a live near-miss: a source URL pointed at a cluster
# frozen months earlier. Nothing about the connection looked wrong: it answered
# queries, reported a believable size, and was not in recovery. Restoring from
# it would have replaced staging with months-old data, and every backup would
# have protected a corpse.
class HarborDbOpsFreshnessTest < ActiveSupport::TestCase
  FROZEN = Time.utc(2026, 3, 18, 14, 12, 34)

  def target = Harbor::DbOps::Target.new("postgresql://u:p@cache-host:5432/shop_cache")

  def test_a_live_database_passes
    with_newest(1.hour.ago) do
      assert Harbor::DbOps::Freshness.assert_fresh!(target, probes: probes, max_age_days: 7)
    end
  end

  def test_an_abandoned_cluster_is_refused
    with_newest(FROZEN) do
      err = assert_raises(Harbor::DbOps::Freshness::Error) do
        Harbor::DbOps::Freshness.assert_fresh!(target, probes: probes, max_age_days: 7)
      end
      assert_match(/looks abandoned/, err.message)
      assert_match(/check the URL/, err.message)
    end
  end

  def test_the_boundary_is_inclusive
    with_newest(168.hours.ago + 1.minute) do
      assert Harbor::DbOps::Freshness.assert_fresh!(target, probes: probes, max_age_days: 7)
    end
    with_newest(168.hours.ago - 1.minute) do
      assert_raises(Harbor::DbOps::Freshness::Error) do
        Harbor::DbOps::Freshness.assert_fresh!(target, probes: probes, max_age_days: 7)
      end
    end
  end

  # An empty database is a legitimate state (a brand new cache), and must not
  # block the first run.
  def test_nothing_to_probe_is_not_treated_as_stale
    with_newest(nil) do
      assert Harbor::DbOps::Freshness.assert_fresh!(target, probes: probes, max_age_days: 7)
    end
  end

  # The newest write across ALL probe tables wins — one cold table must not
  # condemn a database whose other tables are hot.
  def test_the_newest_probe_wins
    stub_newest_in({ "cache_entries" => 2.minutes.ago,
                     "imports" => FROZEN,
                     "snapshots" => FROZEN }) do
      assert Harbor::DbOps::Freshness.assert_fresh!(target, probes: probes, max_age_days: 7)
    end
  end

  def test_a_generous_override_allows_a_stale_source
    with_newest(FROZEN) do
      assert Harbor::DbOps::Freshness.assert_fresh!(target, probes: probes, max_age_days: 100_000)
    end
  end

  def test_age_days_is_nil_without_a_timestamp
    assert_nil Harbor::DbOps::Freshness.age_days(nil)
    assert_in_delta 2.0, Harbor::DbOps::Freshness.age_days(48.hours.ago), 0.01
  end

  private

  def probes = { "cache_entries" => "created_at", "imports" => "created_at", "snapshots" => "updated_at" }

  def with_newest(stamp, &block) = stub_newest_in(Hash.new(stamp), &block)

  # Replace the one method that touches the network.
  def stub_newest_in(by_table)
    original = Harbor::DbOps::Freshness.method(:newest_in)
    Harbor::DbOps::Freshness.define_singleton_method(:newest_in) { |_t, table, _c| by_table[table] }
    yield
  ensure
    Harbor::DbOps::Freshness.define_singleton_method(:newest_in, original)
  end
end
