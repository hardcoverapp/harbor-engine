require "test_helper"

class HarborSettingsTest < ActiveSupport::TestCase
  ENV_KEY = "HARBOR_TEST_AUTO_RETRIES".freeze

  include HarborTestConfig

  setup do
    @exports = []
    Harbor.config.export = ->(path, body) { @exports << [ path, body ] }
    Harbor.config.env_fallback :agent_auto_retries, ENV_KEY
    ENV.delete(ENV_KEY)
  end

  teardown { ENV.delete(ENV_KEY) }

  test "an unsaved setting reads its default" do
    resolved = Harbor::Setting.resolve(:agent_auto_retries)
    assert_equal 3, resolved.value
    assert_equal :default, resolved.source
    assert_equal false, Harbor::Setting.get(:workflows_enabled)
  end

  test "the host's ENV key applies until a value is saved, cast to the setting's type" do
    ENV[ENV_KEY] = "5"
    resolved = Harbor::Setting.resolve(:agent_auto_retries)
    assert_equal 5, resolved.value
    assert_equal :env, resolved.source
    assert_equal ENV_KEY, resolved.env_key

    Harbor::Setting.set!(:agent_auto_retries, "1", by: "Ada")
    resolved = Harbor::Setting.resolve(:agent_auto_retries)
    assert_equal 1, resolved.value
    assert_equal :saved, resolved.source
    assert_equal "Ada", resolved.record.updated_by
  end

  test "a saved off wins over an ENV on" do
    Harbor.config.env_fallback :workflows_enabled, ENV_KEY
    ENV[ENV_KEY] = "true"
    assert_equal true, Harbor::Setting.get(:workflows_enabled)
    Harbor::Setting.set!(:workflows_enabled, "false")
    assert_equal false, Harbor::Setting.get(:workflows_enabled)
  end

  test "an ENV value of the wrong type is ignored for the default" do
    ENV[ENV_KEY] = "lots"
    resolved = Harbor::Setting.resolve(:agent_auto_retries)
    assert_equal 3, resolved.value
    assert_equal :default, resolved.source
  end

  test "a value of the wrong type or out of range is refused and nothing is saved" do
    assert_raises(ArgumentError) { Harbor::Setting.set!(:agent_auto_retries, "many") }
    assert_raises(ArgumentError) { Harbor::Setting.set!(:agent_auto_retries, "-1") }
    assert_raises(ArgumentError) { Harbor::Setting.set!(:agent_auto_retries, "11") }
    assert_raises(ArgumentError) { Harbor::Setting.set!(:workflows_enabled, "maybe") }
    assert_equal 0, Harbor::Setting.count
  end

  test "an undeclared key can't be read or saved" do
    assert_raises(Harbor::Settings::Unknown) { Harbor::Setting.get(:nope) }
    assert_raises(Harbor::Settings::Unknown) { Harbor::Setting.set!(:nope, "1") }
    assert_not Harbor::Setting.new(key: "nope", value: 1).valid?
  end

  test "reset goes back to the ENV fallback or default" do
    Harbor::Setting.set!(:agent_auto_retries, "7")
    Harbor::Setting.reset!(:agent_auto_retries)
    assert_equal 3, Harbor::Setting.get(:agent_auto_retries)
  end

  test "resolve_all covers every declared setting" do
    Harbor::Setting.set!(:workflows_enabled, "true")
    resolved = Harbor::Setting.resolve_all
    assert_equal Harbor::Settings.all.map(&:key), resolved.map { |r| r.definition.key }
    assert_equal :saved, resolved.find { |r| r.definition.key == "workflows_enabled" }.source
  end

  test "saving and resetting hand the saved values to the host's export hook" do
    Harbor::Setting.set!(:agent_auto_retries, "2")
    path, body = @exports.last
    assert_equal "harbor/settings.json", path
    assert_equal({ "agent_auto_retries" => 2 }, JSON.parse(body))

    Harbor::Setting.reset!(:agent_auto_retries)
    assert_equal({}, JSON.parse(@exports.last.last))
  end

  test "a failing export doesn't fail the save" do
    Harbor.config.export = ->(*) { raise "disk full" }
    Harbor::Setting.set!(:agent_auto_retries, "4")
    assert_equal 4, Harbor::Setting.get(:agent_auto_retries)
  end

  test "an ENV fallback can only be named for a declared setting" do
    assert_raises(Harbor::Settings::Unknown) { Harbor.config.env_fallback :nope, "X" }
  end

  test "declaring a key twice or with an unknown type is refused" do
    assert_raises(ArgumentError) do
      Harbor::Settings.declare :workflows_enabled, type: :boolean, default: false, group: "x", label: "x", description: "x"
    end
    assert_raises(ArgumentError) do
      Harbor::Settings.declare :harbor_test_new, type: :float, default: 1, group: "x", label: "x", description: "x"
    end
  end
end
