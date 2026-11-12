require "test_helper"

class HarborModelsTest < ActiveSupport::TestCase
  include HarborTestConfig

  CATALOG = {
    "anthropic" => { "name" => "Anthropic", "models" => {
      "claude-old" => { "id" => "claude-old", "name" => "Claude Old", "release_date" => "2025-01-01", "tool_call" => true, "modalities" => { "output" => [ "text" ] } },
      "claude-new" => { "id" => "claude-new", "name" => "Claude New", "release_date" => "2026-06-01", "tool_call" => true, "modalities" => { "output" => [ "text" ] } },
      "claude-gone" => { "id" => "claude-gone", "name" => "Claude Gone", "release_date" => "2026-07-01", "status" => "deprecated", "tool_call" => true }
    } },
    "openai" => { "name" => "OpenAI", "models" => {
      "gpt-new" => { "id" => "gpt-new", "name" => "gpt-new", "release_date" => "2026-05-01", "tool_call" => true, "modalities" => { "output" => [ "text" ] } },
      "gpt-image" => { "id" => "gpt-image", "name" => "GPT Image", "release_date" => "2026-08-01", "tool_call" => false, "modalities" => { "output" => [ "image" ] } },
      "text-embed" => { "id" => "text-embed", "name" => "Embed", "release_date" => "2026-08-01", "tool_call" => false, "modalities" => { "output" => [ "text" ] } }
    } },
    "someone-else" => { "models" => { "x" => { "id" => "x" } } }
  }.to_json

  setup do
    Harbor::ModelChoice.delete_all
    Harbor::ModelAlias.delete_all
    Harbor::ModelProvider.delete_all
    @anthropic = Harbor::ModelProvider.create!(key: "anthropic")
    @openai = Harbor::ModelProvider.create!(key: "openai")
    @cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @downloads = []
    @download = ->(url) { @downloads << url; CATALOG }
    Harbor::ModelCatalog.http = ->(url) { @download.call(url) }
  end

  teardown do
    Harbor::ModelCatalog.http = nil
    Rails.cache = @cache
  end

  def quick(*choices)
    Harbor::ModelAlias.create!(name: "Quick #{SecureRandom.hex(3)}", model_choices_attributes: choices)
  end

  test "an alias needs a name and at least one model" do
    blank = Harbor::ModelAlias.new(name: "Empty")
    assert_not blank.valid?
    assert_includes blank.errors.full_messages, "Add at least one model."
    assert quick({ model_provider: @anthropic, model: "claude-new" }).persisted?
  end

  test "a choice's model has to belong to its provider" do
    wrong = Harbor::ModelAlias.new(name: "Wrong", model_choices_attributes: [ { model_provider: @anthropic, model: "gpt-new" } ])
    assert_not wrong.valid?
    assert_match "does not match its provider", wrong.errors.full_messages.join
  end

  test "resolve takes the first choice whose provider is on and below the choice's cutoff" do
    model_alias = quick({ model_provider: @anthropic, model: "claude-new", position: 0, cutoff_percent: 80 },
                        { model_provider: @openai, model: "gpt-new", position: 1, cutoff_percent: 100 })
    assert_equal "claude-new", model_alias.resolve.model

    @anthropic.update!(weekly_used_percent: 85, weekly_resets_at: 2.days.from_now)
    assert_equal "gpt-new", model_alias.reload.resolve.model

    @anthropic.update!(weekly_resets_at: 1.minute.ago)
    assert_equal "claude-new", model_alias.reload.resolve.model, "a window that has reset no longer counts"

    @anthropic.update!(enabled: false)
    @openai.update!(enabled: false)
    error = assert_raises(Harbor::ModelAlias::Unavailable) { model_alias.reload.resolve }
    assert_match "disabled or above their usage cutoff", error.message
  end

  test "resolve passes over a choice the backend can't run" do
    backend = Struct.new(:label) do
      def supports?(choice, **) = choice.model_provider.key == "openai"
      def policy_hint(**) = " Try another runtime."
    end.new("the laptop")
    model_alias = quick({ model_provider: @anthropic, model: "claude-new", position: 0 },
                        { model_provider: @openai, model: "gpt-new", position: 1 })
    assert_equal "gpt-new", model_alias.resolve(backend: backend).model

    @openai.update!(enabled: false)
    error = assert_raises(Harbor::ModelAlias::Unavailable) { model_alias.reload.resolve(backend: backend) }
    assert_match "unsupported at the laptop", error.message
    assert_match "Try another runtime.", error.message
  end

  test "a provider with choices can't be deleted, and deleting an alias deletes its choices" do
    model_alias = quick({ model_provider: @anthropic, model: "claude-new" })
    assert_not @anthropic.destroy
    assert_difference("Harbor::ModelChoice.count", -1) { model_alias.destroy }
  end

  test "the catalog lists each provider's agent-capable models, newest first, with no key" do
    assert_equal [ [ "Claude New (claude-new)", "claude-new" ], [ "Claude Old (claude-old)", "claude-old" ] ],
                 Harbor::ModelCatalog.fetch(@anthropic)
    assert_equal [ [ "gpt-new", "gpt-new" ] ], Harbor::ModelCatalog.fetch("openai")
    assert_equal [ "https://models.dev/api.json" ], @downloads, "one download serves every provider"
  end

  test "the catalog is read again when stale, and the old copy is kept if that fails" do
    Harbor::ModelCatalog.fetch(@anthropic)
    travel 13.hours do
      @download = ->(_url) { raise Harbor::ModelCatalog::Unavailable, "down" }
      assert_equal "claude-new", Harbor::ModelCatalog.fetch(@anthropic).first.last
    end
    Harbor::ModelCatalog.clear
    @download = ->(_url) { raise Harbor::ModelCatalog::Unavailable, "down" }
    assert_raises(Harbor::ModelCatalog::Unavailable) { Harbor::ModelCatalog.fetch(@anthropic) }
  end

  test "the catalog's address is a setting, and changing it reads the new one" do
    Harbor::ModelCatalog.fetch(@anthropic)
    Harbor::Setting.set!(:model_catalog_url, "https://example.com/models.json")
    Harbor::ModelCatalog.fetch(@anthropic)
    assert_equal [ "https://models.dev/api.json", "https://example.com/models.json" ], @downloads
  end

  test "a catalog that isn't the expected JSON is reported, not raised as a parse error" do
    assert_raises(Harbor::ModelCatalog::Unavailable) { Harbor::ModelCatalog.parse("<html>") }
    assert_raises(Harbor::ModelCatalog::Unavailable) { Harbor::ModelCatalog.parse("[]") }
  end

  test "only an https address is fetched" do
    assert_raises(Harbor::ModelCatalog::Unavailable) { Harbor::ModelCatalog.send(:download, "http://example.com/models.json") }
    assert_raises(Harbor::ModelCatalog::Unavailable) { Harbor::ModelCatalog.send(:download, "not a url") }
  end
end
