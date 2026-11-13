require "test_helper"

class HarborDbOpsBackupProgressTest < ActiveSupport::TestCase
  setup do
    @run = Harbor::Run.create!(loader: "db-backup", trigger_source: "manual", status: "running")
    @now = Time.utc(2026, 11, 9, 12, 0, 0)
    @lines = []
  end

  test "compares against the last backup and estimates time left" do
    progress = build(expected_bytes: 5.gigabytes)
    @now += 100
    data = progress.call(3.gigabytes)

    assert_equal 60, data["percent"]
    assert_equal 67, data["eta_seconds"], "2 GB left at 30 MB/s"
    assert_equal data, @run.reload.progress
    assert_equal [ "[progress] Shop · cleaned (2 of 6): 3 GB / ~5 GB · 60% · ~2 min left" ], @lines
  end

  test "never shows 100% while running, even past the estimate" do
    progress = build(expected_bytes: 1.gigabyte)
    @now += 10
    data = progress.call(2.gigabytes)
    assert_equal 99, data["percent"]
    assert_nil data["eta_seconds"]
  end

  test "a first backup shows bytes written and the source size, with no percentage" do
    progress = build(expected_bytes: nil, reference_bytes: 40.gigabytes)
    @now += 10
    data = progress.call(1.gigabyte)
    assert_nil data["percent"]
    assert_equal 40.gigabytes, data["reference_bytes"]
    assert_match "1 GB written · source tables 40 GB uncompressed", @lines.last
  end

  test "logs at most once a minute but updates the run every call" do
    progress = build(expected_bytes: 10.gigabytes)
    [ 5, 30, 61, 70 ].each_with_index do |offset, i|
      @now = Time.utc(2026, 11, 9, 12, 0, 0) + offset
      progress.call((i + 1).gigabytes)
    end
    assert_equal 2, @lines.size
    assert_equal 4.gigabytes, @run.reload.progress["bytes"]
  end

  test "time left reads in minutes, then hours" do
    assert_equal "1 min", Harbor::DbOps::BackupProgress.eta(20)
    assert_equal "45 min", Harbor::DbOps::BackupProgress.eta(2700)
    assert_equal "2 h 5 min", Harbor::DbOps::BackupProgress.eta(7500)
  end

  private

  def build(expected_bytes:, reference_bytes: nil)
    Harbor::DbOps::BackupProgress.new(run: @run, label: "Shop · cleaned", step: 2, steps: 6, expected_bytes:,
                              reference_bytes:, logger: ->(line) { @lines << line }, clock: -> { @now })
  end
end
