require "test_helper"

class HarborModelPagesTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  CATALOG = { "anthropic" => [ [ "Claude New (claude-new)", "claude-new" ], [ "Claude Old (claude-old)", "claude-old" ] ],
              "openai" => [ [ "gpt-new", "gpt-new" ] ] }.freeze

  setup do
    [ Harbor::Agent, Harbor::ModelChoice, Harbor::ModelAlias, Harbor::ModelProvider ].each(&:delete_all)
    @anthropic = Harbor::ModelProvider.create!(key: "anthropic", weekly_used_percent: 42.5, weekly_resets_at: 2.days.from_now,
                                               session_used_percent: 10, session_resets_at: 1.hour.from_now, usage_checked_at: 5.minutes.ago)
    @openai = Harbor::ModelProvider.create!(key: "openai")
    @alias = Harbor::ModelAlias.create!(name: "Thinking", description: "For hard problems", model_choices_attributes: [
      { model_provider: @anthropic, model: "claude-saved", effort: "high", position: 0, cutoff_percent: 80 },
      { model_provider: @openai, model: "gpt-new", position: 1, cutoff_percent: 95 } ])
    @cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @catalog = ->(_url) { { "anthropic" => { "models" => CATALOG["anthropic"].each_with_index.map { |(label, id), i| { "id" => id, "name" => label.split(" (").first, "release_date" => "2026-0#{9 - i}-01" } } },
                            "openai" => { "models" => [ { "id" => "gpt-new", "name" => "gpt-new" } ] } }.to_json }
    Harbor::ModelCatalog.http = ->(url) { @catalog.call(url) }
    @changes = 0
    Harbor.config.availability_changed = -> { @changes += 1 }
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    Harbor::ModelCatalog.http = nil
    Rails.cache = @cache
    Harbor.config.availability_changed = nil
    Harbor.config.refresh_model_usage = nil
    Harbor.config.model_name = ->(model) { model }
  end

  test "the Models tab shows each provider's usage and switch" do
    get harbor.models_path
    assert_response :success
    assert_select "nav[data-tabs=models] a[aria-current=page]", text: "Models"
    assert_select "[data-provider=anthropic]" do
      assert_select "h2", "Anthropic"
      assert_select "p", text: /42.5%\s*used this week/
      assert_select "p", text: /10% used of current session/
      assert_select "p", text: /Resets .* \(in 2 days\)/
      assert_select "p", text: /Checked 5 minutes ago/
    end
    assert_select "[data-provider=openai] p", text: /Usage has not been checked/
    assert_select "form[action=?]", harbor.refresh_models_path, count: 0
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Models"
  end

  test "a provider is switched off from the page, and the host is told" do
    patch harbor.model_provider_path(@anthropic), params: { model_provider: { enabled: false } }
    assert_redirected_to harbor.models_path
    assert_not @anthropic.reload.enabled?
    assert_equal 1, @changes
    assert_equal "Anthropic disabled for queued and future runs.", flash[:notice]
  end

  test "refreshing usage is offered only when the host can do it" do
    post harbor.refresh_models_path
    assert_response :not_found
    asked = []
    Harbor.config.refresh_model_usage = ->(user) { asked << user; Harbor::Run.create!(skill: "model-usage", status: "queued") }
    get harbor.models_path
    assert_select "form[action=?]", harbor.refresh_models_path
    post harbor.refresh_models_path
    assert_redirected_to harbor.models_path
    assert_match(/Refreshing usage\. Follow progress in run #\d+\./, flash[:notice])
    assert_equal 1, asked.size
  end

  test "the Aliases tab lists each alias's models in order, named as the host names them" do
    Harbor.config.model_name = ->(model) { model.upcase }
    get harbor.models_path(tab: "aliases")
    assert_select "nav[data-tabs=models] a[aria-current=page]", text: "Aliases"
    assert_select "[data-model-alias='#{@alias.id}']" do
      assert_select "a", text: "Thinking"
      assert_select "li:first-child", text: /Primary\s*CLAUDE-SAVED\s*Anthropic\s*· high\s*Skip at 80% used/
      assert_select "li:last-child", text: /Backup 1\s*GPT-NEW\s*OpenAI\s*Skip at 95% used/
    end
    assert_select "a[href=?]", harbor.new_model_alias_path
  end

  test "the alias form offers each provider's catalog, and keeps a saved model the catalog lacks" do
    get harbor.edit_model_alias_path(@alias)
    assert_response :success
    assert_select "form[data-controller='harbor--nested-fields'][action=?]", harbor.model_alias_path(@alias)
    assert_select "[data-controller='harbor--model-picker']", minimum: 2 do |rows|
      options = JSON.parse(rows.first["data-harbor--model-picker-options-value"])
      assert_equal CATALOG["anthropic"] + [ %w[claude-saved claude-saved] ], options[@anthropic.id.to_s]
      assert_equal CATALOG["openai"], options[@openai.id.to_s]
    end
    assert_select "option[value='claude-saved'][selected]"
    assert_select "option[value='claude-new']"
    assert_select "[role=alert]", count: 0
  end

  test "when the catalog can't be read, saved models are still offered and the page says so once" do
    @catalog = ->(_url) { raise Harbor::ModelCatalog::Unavailable, "Could not reach the model catalog." }
    get harbor.edit_model_alias_path(@alias)
    assert_response :success
    assert_select "[role=alert]", text: "Could not reach the model catalog. Previously saved models are still available."
    assert_select "option[value='claude-saved'][selected]"
  end

  test "an alias is created, edited and deleted" do
    get harbor.new_model_alias_path
    assert_select "form[action=?]", harbor.model_aliases_path

    post harbor.model_aliases_path, params: { model_alias: { name: "", model_choices_attributes: { "0" => { model_provider_id: @openai.id, model: "gpt-new" } } } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Name can't be blank/
    assert_select "option[value='gpt-new'][selected]"

    post harbor.model_aliases_path, params: { model_alias: { name: "Quick", model_choices_attributes: {
      "0" => { model_provider_id: @openai.id, model: "gpt-new", position: 0, cutoff_percent: 90 } } } }
    assert_redirected_to harbor.models_path(tab: "aliases")
    quick = Harbor::ModelAlias.find_by!(name: "Quick")

    patch harbor.model_alias_path(quick), params: { model_alias: { model_choices_attributes: {
      "1" => { model_provider_id: @anthropic.id, model: "claude-new", effort: "low", position: 1, cutoff_percent: 100 } } } }
    assert_redirected_to harbor.models_path(tab: "aliases")
    assert_equal %w[gpt-new claude-new], quick.reload.model_choices.map(&:model)
    assert_equal 1, @changes

    delete harbor.model_alias_path(@alias)
    assert_equal "Model alias deleted.", flash[:notice]
    assert_not Harbor::ModelAlias.exists?(@alias.id)
  end
end
