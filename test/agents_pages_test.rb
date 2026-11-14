require "test_helper"

# The Agents pages: the list with its task routing and shared context tabs, an
# agent's own page, its form and its avatar. What a site with no code of its
# own gets, and each place a host can add to.
class HarborAgentsPagesTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ1sAAAAASUVORK5CYII=").b.freeze
  GIF = Base64.decode64("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7").b.freeze

  # A host's agent class: a name of its own for one of Harbor's columns.
  class HostAgent < Harbor::Agent
    alias_attribute :capacity, :max_agents
  end

  # A host's routing: a task type goes only to agents that list it, and the
  # page says so in the host's words.
  class HostTaskAssignment < Harbor::TaskAssignment
    def self.compatible_agents(task_type) = super.where("default_tasks @> ?", [ task_type ].to_json)

    def self.refusal(task_type, agent_key) = "#{agent_key} hasn't been trained for #{task_type}."
  end

  HOST_VIEWS = File.expand_path("fixtures/host_views/extras", __dir__)
  CONFIG = %i[agent_class task_assignment_class agent_params agent_edited].freeze

  setup do
    [ Harbor::TaskAssignment, Harbor::AgentDocument, Harbor::AgentSetting, Harbor::Agent, Harbor::WorkspaceProfileRuntime,
      Harbor::WorkspaceProfile, Harbor::Runtime, Harbor::ModelChoice, Harbor::ModelAlias, Harbor::ModelProvider ].each(&:delete_all)
    Harbor::TaskTypes.reset!
    Harbor::TaskTypes.declare "review"
    Harbor::TaskTypes.declare "rebase", fallback: "review"
    @config = CONFIG.index_with { |name| Harbor.config.public_send(name) }
    @view_paths = Harbor::AgentsController.view_paths

    provider = Harbor::ModelProvider.create!(key: "anthropic")
    @alias = Harbor::ModelAlias.create!(name: "Thinking", model_choices_attributes: [ { model_provider: provider, model: "claude-sonnet-5-5" } ])
    @quick = Harbor::ModelAlias.create!(name: "Quick", model_choices_attributes: [ { model_provider: provider, model: "claude-haiku-5-5" } ])
    runtime = Harbor::Runtime.create!(key: "laptop", name: "Laptop", backend: "orca", config: { "repo" => "name:app" })
    @workspace = Harbor::WorkspaceProfile.create!(name: "Default", workspace_profile_runtimes_attributes: [ { runtime: runtime, position: 0 } ])
    @writer = Harbor::Agent.create!(key: "writer", name: "Wren", description: "Writes the release notes.", system_prompt: "Write plainly.",
                                    model_alias: @alias, workspace_profile: @workspace, max_workspaces: 2, max_agents: 6,
                                    tools: { "allowed" => %w[Read] }, default_tasks: %w[review])
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    @config.each { |name, value| Harbor.config.public_send("#{name}=", value) }
    Harbor::AgentsController.view_paths = @view_paths
    Harbor::TaskTypes.reset!
  end

  # What a host does: a views folder of its own, looked in before Harbor's.
  def host_views = Harbor::AgentsController.prepend_view_path(HOST_VIEWS)

  def upload(bytes = PNG, content_type: "image/png", filename: "avatar.png")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, original_filename: filename)
  end

  # Saves the form as a browser would: the alias is always sent.
  def update_agent(agent = @writer, **attributes)
    patch harbor.agent_path(agent), params: { agent: { model_alias_id: @alias.id }.merge(attributes) }
  end

  def current_tab = css_select("nav[data-tabs='agents'] a[aria-current='page']").map { |a| a.text.strip }

  def current_page = css_select("[data-harbor-nav] a[aria-current=page]").map { |a| a.text.strip }

  # --- the list and its tabs ---

  test "the list shows each agent with its model, where it runs, what it does and when it changed" do
    Harbor::Agent.create!(key: "archivist", enabled: false)
    get harbor.agents_path
    assert_response :success
    assert_select "title", text: "Agents"
    assert_select "a[href=?]", harbor.new_agent_path, text: "New agent"
    assert_equal [ "Agents" ], current_tab
    assert_select "nav[data-tabs='agents'] a", count: 3
    assert_equal %w[writer archivist], css_select("tr[data-agent]").map { |row| row["data-agent"] }, "enabled agents come first"
    assert_equal %w[Agent Model Runs\ on Does Updated], css_select("thead th").map { |th| th.text.strip }
    assert_select "tr[data-agent=writer]" do
      assert_select "a[href=?]", harbor.agent_path(@writer), text: "Wren"
      assert_select "span[aria-hidden=true]", text: "W", count: 1
      assert_select "td", text: /Thinking/
      assert_select "td", text: /Default\s+2 workspaces · 6 agents/
      assert_select "td", text: /Writes the release notes\./
      assert_select "td", text: /less than a minute ago/
      assert_select ".pill", count: 0
    end
    assert_select "tr[data-agent=archivist].opacity-45 .pill", text: "disabled"
    assert_select "form[action=?]", harbor.context_agents_path, count: 0, message: "each tab shows only its own"
    assert_equal [ "Agents" ], current_page
  end

  test "an agent is a card on a phone and a table row from lg up" do
    get harbor.agents_path
    assert_select "table.block.lg\\:table thead.hidden.lg\\:table-header-group", count: 1
    assert_select "tr[data-agent=writer].grid.lg\\:table-row td.block.lg\\:table-cell", count: 5
    assert_select "tr[data-agent=writer] td span.lg\\:hidden", count: 4, message: "each fact carries its label when stacked"
    assert_select "tr[data-agent=writer] a[class*='overflow-wrap:anywhere']", count: 1
  end

  test "with no agents the list says so" do
    Harbor::Agent.delete_all
    get harbor.agents_path
    assert_response :success
    assert_select "p", text: "No agents yet."
    assert_select "table", count: 0
  end

  test "a tab that doesn't exist is the agents tab" do
    get harbor.agents_path(tab: "nonsense")
    assert_response :success
    assert_equal [ "Agents" ], current_tab
    assert_select "tr[data-agent=writer]", count: 1
  end

  # --- an agent's page ---

  test "an agent's page shows who it is, how it runs, its prompt, documents, tools and configuration" do
    @writer.update!(configuration: { "voice" => "plain" })
    @writer.agent_documents.create!(path: "style/tone.md", body: "Warm, never chirpy.")
    get harbor.agent_path(@writer)
    assert_response :success
    assert_select "title", text: "Wren"
    assert_select "h1", text: "Wren"
    assert_select "header p", text: "Writes the release notes."
    assert_select "a[href=?]", harbor.edit_agent_path(@writer), text: "Edit agent"
    facts = css_select("[data-agent-facts] > div").map { |fact| [ fact.at("dt").text, fact.at("dd").text ] }
    assert_equal [ %w[Key writer], [ "Model alias", "Thinking" ], %w[Workspace Default], [ "Max workspaces", "2" ],
                   [ "Max agents", "6" ], %w[Status Enabled] ], facts
    assert_equal [ "System prompt", "style/tone.md", "Tools", "Default tasks", "Additional configuration" ], css_select("h2").map(&:text)
    assert_select "pre", text: "Write plainly."
    assert_select "pre", text: "Warm, never chirpy."
    assert_select "pre", text: /"allowed": \[\s+"Read"\s+\]/
    assert_select "pre", text: /"review"/
    assert_select "pre", text: /"voice": "plain"/
    assert_equal [ "Agents" ], current_page, "the menu marks Agents on an agent's page"
  end

  test "an agent with nothing set still has a page" do
    bare = Harbor::Agent.create!(key: "bare", enabled: false)
    get harbor.agent_path(bare)
    assert_response :success
    assert_select "h1", text: "bare"
    assert_select "pre", text: "No system prompt configured."
    assert_select "[data-agent-facts] dd", text: "Disabled"
    assert_select "span[aria-hidden=true]", text: "B"
  end

  test "an agent that doesn't exist is not found" do
    get harbor.agent_path(0)
    assert_response :not_found
    get harbor.edit_agent_path(0)
    assert_response :not_found
  end

  # --- creating and editing ---

  test "the form has every field, with the aliases and workspaces to pick from" do
    get harbor.new_agent_path
    assert_response :success
    assert_select "title", text: "New agent"
    assert_select "span.h-20.rounded-full[aria-hidden=true]", text: "?", count: 1
    assert_select "form[action=?][enctype='multipart/form-data']", harbor.agents_path do
      assert_select "input[type=file][name='agent[avatar]'][accept='image/png,image/jpeg,image/gif,image/webp']"
      assert_select "input[name='agent[remove_avatar]']", count: 0, message: "nothing to remove yet"
      assert_select "input[name='agent[key]'][required]:not([readonly])"
      assert_select "input[name='agent[name]']"
      assert_select "textarea[name='agent[description]']"
      assert_equal [ "Choose an alias", "Quick", "Thinking" ], css_select("select[name='agent[model_alias_id]'][required] option").map(&:text)
      assert_equal [ "Default" ], css_select("select[name='agent[workspace_profile_id]'] option").map(&:text)
      assert_select "input[type=number][name='agent[max_workspaces]'][min='1'][value='1']"
      assert_select "input[type=number][name='agent[max_agents]'][min='1'][value='5']"
      assert_select "input[type=checkbox][name='agent[enabled]'][checked]"
      assert_select "textarea[name='agent[system_prompt]']"
      assert_select "textarea[name='agent[tools]']", text: "{}"
      assert_select "textarea[name='agent[default_tasks]']", text: "[]"
      assert_select "textarea[name='agent[configuration]']", text: "{}"
      assert_select "input[type=submit][value='Save agent']"
      assert_select "a[href=?]", harbor.agents_path, text: "Cancel"
    end
    assert_select "a[href=?]", harbor.models_path, text: "Manage model aliases"
    assert_select "a[href=?]", harbor.workspace_profiles_path, text: "Manage workspaces"
    assert_equal [ "Agents" ], current_page
  end

  test "an agent is created from the form and its page opens" do
    assert_difference "Harbor::Agent.count" do
      post harbor.agents_path, params: { agent: {
        key: "editor", name: "Edith", description: "Tightens prose.", model_alias_id: @quick.id, workspace_profile_id: @workspace.id,
        max_workspaces: 3, max_agents: 9, enabled: "1", system_prompt: "Cut every spare word.",
        tools: '{"allowed":["Read","Edit"],"permission_mode":"acceptEdits"}', default_tasks: '["review"]', configuration: '{"voice":"dry"}'
      } }
    end
    editor = Harbor::Agent.find_by!(key: "editor")
    assert_redirected_to harbor.agent_path(editor)
    assert_equal "Agent saved. Changes apply to new runs.", flash[:notice]
    assert_equal [ "Edith", "Tightens prose.", @quick, @workspace, 3, 9, true, "Cut every spare word." ],
                 [ editor.name, editor.description, editor.model_alias, editor.workspace_profile, editor.max_workspaces,
                   editor.max_agents, editor.enabled, editor.system_prompt ]
    assert_equal({ "allowed" => %w[Read Edit], "permission_mode" => "acceptEdits" }, editor.tools)
    assert_equal %w[review], editor.default_tasks
    assert_equal({ "voice" => "dry" }, editor.configuration)
  end

  test "JSON fields left empty are an empty object and an empty list" do
    post harbor.agents_path, params: { agent: { key: "plain", model_alias_id: @alias.id, tools: "", default_tasks: "", configuration: "" } }
    plain = Harbor::Agent.find_by!(key: "plain")
    assert_equal [ {}, [], {} ], [ plain.tools, plain.default_tasks, plain.configuration ]
  end

  test "an agent is edited from the form; its key never changes" do
    get harbor.edit_agent_path(@writer)
    assert_response :success
    assert_select "title", text: "Edit Wren"
    assert_select "form[action=?]", harbor.agent_path(@writer) do
      assert_select "input[name='agent[key]'][readonly][value=writer]"
      assert_select "select[name='agent[model_alias_id]'] option[selected]", text: "Thinking"
      assert_select "select[name='agent[workspace_profile_id]'] option[selected]", text: "Default"
      assert_select "textarea[name='agent[system_prompt]']", text: "Write plainly."
      assert_select "textarea[name='agent[tools]']", text: /"allowed"/
    end

    update_agent(key: "renamed", name: "Wrenna", enabled: "0", max_workspaces: 4, model_alias_id: @quick.id, system_prompt: "Write warmly.")
    assert_redirected_to harbor.agent_path(@writer)
    @writer.reload
    assert_equal [ "writer", "Wrenna", false, 4, @quick, "Write warmly." ],
                 [ @writer.key, @writer.name, @writer.enabled, @writer.max_workspaces, @writer.model_alias, @writer.system_prompt ]
  end

  test "an agent needs a model alias" do
    assert_no_difference "Harbor::Agent.count" do
      post harbor.agents_path, params: { agent: { key: "aliasless", name: "Typed name" } }
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: "Model alias must be selected"
    assert_select "input[name='agent[name]'][value='Typed name']", count: 1, message: "what was typed stays in the form"

    patch harbor.agent_path(@writer), params: { agent: { model_alias_id: "", name: "Unsaved" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: "Model alias must be selected"
    assert_equal "Wren", @writer.reload.name
  end

  test "a key must be given, well formed and not taken" do
    { "" => /Key can't be blank/, "Has Spaces" => /Key is invalid/, "writer" => /Key has already been taken/ }.each do |key, message|
      assert_no_difference "Harbor::Agent.count" do
        post harbor.agents_path, params: { agent: { key: key, model_alias_id: @alias.id } }
      end
      assert_response :unprocessable_entity, key
      assert_select "[role=alert]", text: message
    end
  end

  test "limits must be whole numbers above zero" do
    update_agent(max_workspaces: 0, name: "Unsaved")
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Max workspaces must be greater than 0/
    update_agent(max_agents: 0)
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Max agents must be greater than 0/
    assert_equal [ "Wren", 2, 6 ], @writer.reload.then { |agent| [ agent.name, agent.max_workspaces, agent.max_agents ] }
  end

  test "JSON that doesn't parse is refused, and what was typed stays in the form" do
    update_agent(name: "Typed name", system_prompt: "Unsaved", configuration: "{bad", tools: '{"allowed":[]}', default_tasks: '["rebase"]')
    assert_response :unprocessable_entity
    assert_select "[role=alert]", count: 1
    assert_select "textarea[name='agent[configuration]']", text: "{bad"
    assert_select "textarea[name='agent[tools]']", text: '{"allowed":[]}'
    assert_select "textarea[name='agent[default_tasks]']", text: '["rebase"]'
    assert_select "input[name='agent[name]'][value='Typed name']"
    assert_select "textarea[name='agent[system_prompt]']", text: "Unsaved"
    @writer.reload
    assert_equal [ "Wren", "Write plainly.", {}, %w[review] ], [ @writer.name, @writer.system_prompt, @writer.configuration, @writer.default_tasks ]
  end

  test "JSON of the wrong shape is refused, field by field" do
    { { tools: "[]" } => "Tools must be a JSON object.", { default_tasks: "{}" } => "Default tasks must be a JSON array.",
      { configuration: '"text"' } => "Configuration must be a JSON object." }.each do |fields, message|
      update_agent(**fields)
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: message
    end
    assert_equal({ "allowed" => %w[Read] }, @writer.reload.tools)

    assert_no_difference "Harbor::Agent.count" do
      post harbor.agents_path, params: { agent: { key: "shapeless", model_alias_id: @alias.id, tools: "[1]" } }
    end
    assert_response :unprocessable_entity
    assert_select "input[name='agent[key]'][value=shapeless]", count: 1
  end

  # --- documents ---

  test "the form has a row per document and a template for another" do
    doc = @writer.agent_documents.create!(path: "notes.md", body: "Remember the changelog.")
    get harbor.edit_agent_path(@writer)
    assert_select "[data-controller='harbor--nested-fields']" do
      assert_select "[data-harbor--nested-fields-target=list] [data-harbor-nested-row]", count: 1
      assert_select "[data-harbor--nested-fields-target=list] input[type=hidden][name='agent[agent_documents_attributes][0][id]'][value='#{doc.id}']"
      assert_select "[data-harbor--nested-fields-target=list] input[name='agent[agent_documents_attributes][0][path]'][value='notes.md']"
      assert_select "[data-harbor--nested-fields-target=list] textarea[name='agent[agent_documents_attributes][0][body]']", text: "Remember the changelog."
      assert_select "[data-harbor--nested-fields-target=list] input[type=checkbox][name='agent[agent_documents_attributes][0][_destroy]']"
      assert_select "button[data-action='harbor--nested-fields#add']", text: "Add markdown document"
    end
    template = css_select("template[data-harbor--nested-fields-target=template]").first
    assert_includes template.inner_html, "agent[agent_documents_attributes][NEW_RECORD][path]"
    assert_includes template.inner_html, "data-harbor-nested-row"
  end

  test "documents are added, edited and removed with the agent" do
    update_agent(agent_documents_attributes: { "1791575000000001" => { path: "memory/facts.md", body: "The notes go out on Fridays." },
                                               "1791575000000002" => { path: "", body: "" } })
    assert_redirected_to harbor.agent_path(@writer)
    doc = @writer.agent_documents.sole
    assert_equal [ "memory/facts.md", "The notes go out on Fridays." ], [ doc.path, doc.body ]
    assert_match "The notes go out on Fridays.", @writer.reload.full_system_prompt

    update_agent(agent_documents_attributes: { "0" => { id: doc.id, path: "memory/dates.md", body: "Thursdays now." } })
    assert_equal [ "memory/dates.md", "Thursdays now." ], doc.reload.then { |d| [ d.path, d.body ] }

    update_agent(agent_documents_attributes: { "0" => { id: doc.id, _destroy: "1" } })
    assert_redirected_to harbor.agent_path(@writer)
    assert_empty @writer.agent_documents.reload
  end

  test "a document whose path isn't a relative Markdown file is refused, and nothing is saved" do
    update_agent(name: "Unsaved", agent_documents_attributes: { "0" => { path: "notes.txt", body: "x" } })
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Agent documents path is invalid/
    assert_select "input[name='agent[agent_documents_attributes][0][path]'][value='notes.txt']", count: 1
    assert_equal "Wren", @writer.reload.name
    assert_empty @writer.agent_documents
  end

  # --- the avatar ---

  test "an avatar is uploaded with a new agent and kept in the database" do
    post harbor.agents_path, params: { agent: { key: "painter", model_alias_id: @alias.id, avatar: upload } }
    painter = Harbor::Agent.find_by!(key: "painter")
    assert_redirected_to harbor.agent_path(painter)
    assert_equal [ PNG, "image/png" ], [ painter.avatar_data, painter.avatar_content_type ]
  end

  test "an avatar shows in the list, on the agent's page and in its form, where it can be removed" do
    update_agent(avatar: upload)
    assert_redirected_to harbor.agent_path(@writer)
    address = harbor.avatar_agent_path(@writer, v: @writer.reload.updated_at.to_f)
    { harbor.agents_path => "h-10", harbor.agent_path(@writer) => "h-20", harbor.edit_agent_path(@writer) => "h-20" }.each do |path, size|
      get path
      assert_response :success
      assert_select "img.#{size}.rounded-full[src=?][alt='']", address, count: 1
    end
    assert_select "input[type=checkbox][name='agent[remove_avatar]']", count: 1
  end

  test "the image is served as it was stored, for the browser's own cache only" do
    @writer.update!(avatar: StringIO.new(GIF))
    get harbor.avatar_agent_path(@writer)
    assert_response :success
    assert_equal GIF, response.body.b
    assert_equal "image/gif", response.media_type
    assert_match(/inline/, response.headers["Content-Disposition"])
    assert_match(/private/, response.headers["Cache-Control"])
    assert_no_match(/public/, response.headers["Cache-Control"])
    etag, modified = response.headers.values_at("ETag", "Last-Modified")
    assert etag.present? && modified.present?

    get harbor.avatar_agent_path(@writer), headers: { "If-None-Match" => etag }
    assert_response :not_modified
    assert_empty response.body

    @writer.update!(avatar: StringIO.new(PNG))
    get harbor.avatar_agent_path(@writer), headers: { "If-None-Match" => etag }
    assert_response :success, "a new image is sent, whatever the browser holds"
    assert_equal PNG, response.body.b
  end

  test "an agent with no avatar has none to serve, and shows its initial" do
    get harbor.avatar_agent_path(@writer)
    assert_response :not_found
    get harbor.avatar_agent_path(0)
    assert_response :not_found
    get harbor.agent_path(@writer)
    assert_select "img", count: 0
    assert_select "span.h-20.rounded-full[aria-hidden=true]", text: "W"
  end

  test "an avatar is removed, a replacement wins over removal, and other edits leave it alone" do
    update_agent(avatar: upload)
    update_agent(name: "Wrenna")
    assert_equal PNG, @writer.reload.avatar_data

    update_agent(remove_avatar: "1", avatar: upload(GIF, content_type: "image/gif", filename: "avatar.gif"))
    assert_equal [ GIF, "image/gif" ], @writer.reload.then { |agent| [ agent.avatar_data, agent.avatar_content_type ] }

    update_agent(remove_avatar: "1")
    assert_redirected_to harbor.agent_path(@writer)
    assert_equal [ nil, nil ], @writer.reload.then { |agent| [ agent.avatar_data, agent.avatar_content_type ] }
    get harbor.avatar_agent_path(@writer)
    assert_response :not_found
  end

  test "an upload is judged by its bytes: not an image, or too large, is refused and the stored one kept" do
    update_agent(avatar: upload(PNG, content_type: "text/plain", filename: "wrong.txt"))
    assert_equal "image/png", @writer.reload.avatar_content_type

    [ "<script>alert('no')</script>", '<svg xmlns="http://www.w3.org/2000/svg"></svg>' ].each do |bytes|
      update_agent(avatar: upload(bytes), name: "Unsaved")
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Avatar must be a PNG, JPEG, GIF, or WebP image/
    end
    update_agent(avatar: upload(PNG + "x" * Harbor::Agent::MAX_AVATAR_SIZE))
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Avatar must be 2 MB or smaller/
    assert_equal [ PNG, "Wren" ], @writer.reload.then { |agent| [ agent.avatar_data, agent.name ] }
  end

  test "a removal that couldn't be saved stays ticked, and an upload beside a mistake isn't kept" do
    update_agent(avatar: upload)
    update_agent(max_workspaces: 0, remove_avatar: "1")
    assert_response :unprocessable_entity
    assert_select "input[type=checkbox][name='agent[remove_avatar]'][checked]", count: 1
    update_agent(configuration: "{bad", avatar: upload(GIF, content_type: "image/gif", filename: "avatar.gif"))
    assert_response :unprocessable_entity
    assert_equal PNG, @writer.reload.avatar_data
  end

  test "the avatar helper draws an agent on any page: its image, or its initial" do
    helper = ApplicationController.new.tap { |c| c.request = ActionDispatch::TestRequest.create }.helpers
    assert_match %r{\A<span aria-hidden="true" class="h-4 w-4 [^"]*">W</span>\z}, helper.harbor_agent_avatar(@writer, size: :xs)
    assert_match %r{>\?</span>\z}, helper.harbor_agent_avatar(Harbor::Agent.new)
    @writer.update!(avatar: StringIO.new(PNG))
    image = helper.harbor_agent_avatar(@writer)
    assert_includes image, %(src="/factory/agents/#{@writer.id}/avatar?v=#{@writer.updated_at.to_f}")
    assert_includes image, "h-10 w-10"
  end

  # --- task routing ---

  test "the routing tab lists every declared task type with the agents it can be given to" do
    Harbor::Agent.create!(key: "editor", model_alias: @quick)
    Harbor::Agent.create!(key: "retired", enabled: false)
    Harbor::TaskAssignment.create!(task_type: "rebase", agent_key: "editor")
    get harbor.agents_path(tab: "routing")
    assert_response :success
    assert_equal [ "Task routing" ], current_tab
    assert_equal [ "Agents" ], current_page, "the menu marks Agents on the routing tab"
    assert_equal %w[review rebase], css_select("tr[data-task-type]").map { |row| row["data-task-type"] }
    assert_equal %w[Task Agent], css_select("thead th").map { |th| th.text.strip }
    assert_select "tr[data-task-type=review] form[action=?]", harbor.task_assignment_path("review") do
      assert_select "input[name=_method][value=patch]"
      assert_equal [ "unassigned", "editor (Quick)", "writer (Thinking)" ], css_select("select[name=agent_key] option").map { |o| o.text.strip }.first(3)
      assert_select "select[name=agent_key][aria-label='Agent for review'] option[selected]", text: "unassigned"
    end
    assert_select "tr[data-task-type=rebase] select option", count: 2, message: "an assigned type has no unassigned option"
    assert_select "tr[data-task-type=rebase] select option[selected]", text: /editor \(Quick\)/
    assert_select "tr[data-task-type] option", text: /retired/, count: 0
    assert_select "a[href=?]", harbor.agent_path(@writer), count: 0
  end

  test "with no task types declared the routing tab says so" do
    Harbor::TaskTypes.reset!
    get harbor.agents_path(tab: "routing")
    assert_response :success
    assert_select "p", text: "No task types are declared."
    assert_select "table", count: 0
  end

  test "a task type is given to an agent, and then to another" do
    patch harbor.task_assignment_path("review"), params: { agent_key: "writer" }
    assert_redirected_to harbor.agents_path(tab: "routing")
    assert_equal "review → writer (next run uses it).", flash[:notice]
    assert_equal @writer, Harbor::TaskAssignment.agent_for("review")

    Harbor::Agent.create!(key: "editor")
    assert_no_difference "Harbor::TaskAssignment.count" do
      patch harbor.task_assignment_path("review"), params: { agent_key: "editor" }
    end
    assert_equal "editor", Harbor::TaskAssignment.find_by!(task_type: "review").agent_key
  end

  test "an agent that isn't offered is refused: switched off, unknown, or none" do
    Harbor::Agent.create!(key: "retired", enabled: false)
    [ "retired", "nobody", "" ].each do |key|
      assert_no_difference "Harbor::TaskAssignment.count" do
        patch harbor.task_assignment_path("review"), params: { agent_key: key }
      end
      assert_redirected_to harbor.agents_path(tab: "routing")
      assert_equal "#{key.inspect} isn't an enabled agent that review can be given to.", flash[:alert]
    end
  end

  test "a task type that isn't declared is refused" do
    assert_no_difference "Harbor::TaskAssignment.count" do
      patch harbor.task_assignment_path("holiday"), params: { agent_key: "writer" }
    end
    assert_redirected_to harbor.agents_path(tab: "routing")
    assert_equal '"holiday" isn\'t a task type.', flash[:alert]
  end

  test "a host's task assignment class decides who is offered, and says why not" do
    Harbor.config.task_assignment_class = "HarborAgentsPagesTest::HostTaskAssignment"
    Harbor::Agent.create!(key: "editor", default_tasks: %w[rebase])
    get harbor.agents_path(tab: "routing")
    assert_equal [ "unassigned", "writer (Thinking)" ], css_select("tr[data-task-type=review] option").map { |o| o.text.strip }
    assert_select "tr[data-task-type=rebase] option", text: /editor/, count: 1

    patch harbor.task_assignment_path("review"), params: { agent_key: "editor" }
    assert_redirected_to harbor.agents_path(tab: "routing")
    assert_equal "editor hasn't been trained for review.", flash[:alert]
    assert_nil Harbor::TaskAssignment.find_by(task_type: "review")

    patch harbor.task_assignment_path("rebase"), params: { agent_key: "editor" }
    assert_equal "editor", Harbor::TaskAssignment.find_by!(task_type: "rebase").agent_key
  end

  # --- shared context ---

  test "the context tab has the house context and each shared document, each with its own form" do
    Harbor::AgentSetting.create!(key: "house_context", body: "Be kind.")
    Harbor::AgentSetting.create!(key: "shared/guides/tone.md", body: "Plain words.")
    Harbor::AgentSetting.create!(key: "unrelated", body: "Not shown.")
    get harbor.agents_path(tab: "context")
    assert_response :success
    assert_equal [ "Shared context" ], current_tab
    assert_select "form[action=?]", harbor.context_agents_path, count: 2
    assert_select "form textarea[name=body]", text: "Be kind.", count: 1
    assert_select "details[data-shared-document='shared/guides/tone.md']" do
      assert_select "summary", text: "guides/tone.md"
      assert_select "input[type=hidden][name=key][value='shared/guides/tone.md']"
      assert_select "textarea[name=body]", text: "Plain words."
    end
    assert_select "textarea", text: "Not shown.", count: 0
    assert_select "tr[data-agent]", count: 0
  end

  test "the house context is saved, and is what every agent is told from then on" do
    patch harbor.context_agents_path, params: { body: "Be kind." }
    assert_redirected_to harbor.agents_path(tab: "context")
    assert_equal "Shared context updated for new runs.", flash[:notice]
    assert_equal "Be kind.", Harbor::AgentSetting.find_by!(key: "house_context").body
    assert_match(/\ABe kind\./, @writer.full_system_prompt)

    assert_no_difference "Harbor::AgentSetting.count" do
      patch harbor.context_agents_path, params: { key: "", body: "Be kind and brief." }
    end
    assert_equal "Be kind and brief.", Harbor::AgentSetting.find_by!(key: "house_context").body
  end

  test "a shared document is saved under its own key" do
    patch harbor.context_agents_path, params: { key: "shared/guides/tone.md", body: "Plain words." }
    assert_redirected_to harbor.agents_path(tab: "context")
    assert_equal "Plain words.", Harbor::AgentSetting.find_by!(key: "shared/guides/tone.md").body
    patch harbor.context_agents_path, params: { key: "shared/guides/tone.md", body: "Plainer words." }
    assert_equal [ "Plainer words." ], Harbor::AgentSetting.shared_documents.map(&:body)
  end

  test "a key that is neither the house context nor a shared Markdown document is refused" do
    [ "unrelated", "shared/notes.txt", "shared/has space.md", "shared/", "house_context.md", "page_agents" ].each do |key|
      assert_no_difference "Harbor::AgentSetting.count" do
        patch harbor.context_agents_path, params: { key: key, body: "x" }
      end
      assert_response :unprocessable_entity, key
    end
  end

  # --- what a host adds ---

  test "with no partials of the host's, the pages have only Harbor's own" do
    [ harbor.agents_path, harbor.agents_path(tab: "routing"), harbor.agent_path(@writer), harbor.edit_agent_path(@writer) ].each do |path|
      get path
      assert_response :success
      assert_select "[data-host-head], [data-host-cell], [data-host-routing-head], [data-host-routing-cell], [data-host-fact], [data-host-field]", count: 0
    end
  end

  test "a host's columns join the agents table: after the agent, and before when it changed" do
    host_views
    @writer.agent_documents.create!(path: "notes.md", body: "x")
    get harbor.agents_path
    assert_response :success
    assert_equal %w[Agent Initial Model Runs\ on Does Documents Updated], css_select("thead th").map { |th| th.text.strip }
    cells = css_select("tr[data-agent=writer] td")
    assert_equal 7, cells.size
    assert_equal [ "first", "W" ], [ cells[1]["data-host-cell"], cells[1].text.strip ]
    assert_equal [ "last", "1 documents" ], [ cells[5]["data-host-cell"], cells[5].text.strip ]
  end

  test "a host's columns join the routing table, between the task and its agent" do
    host_views
    Harbor::TaskAssignment.create!(task_type: "rebase", agent_key: "writer")
    get harbor.agents_path(tab: "routing")
    assert_response :success
    assert_equal %w[Task Urgency Agent], css_select("thead th").map { |th| th.text.strip }
    assert_select "tr[data-task-type=review] td:nth-child(2)[data-host-routing-cell=review]", text: "nobody yet"
    assert_select "tr[data-task-type=rebase] td:nth-child(2)[data-host-routing-cell=rebase]", text: "given to writer"
  end

  test "a host's facts sit among an agent's own, and its fields in the form" do
    host_views
    get harbor.agent_path(@writer)
    assert_equal [ "Key", "Model alias", "Capacity", "Workspace", "Max workspaces", "Max agents", "Status" ], css_select("[data-agent-facts] dt").map(&:text)
    assert_select "[data-agent-facts] [data-host-fact=writer] dd", text: "6 at once"

    Harbor.config.agent_class = "HarborAgentsPagesTest::HostAgent"
    get harbor.edit_agent_path(@writer)
    assert_response :success
    assert_select "form [data-host-field=writer] input[type=number][name='agent[capacity]'][value='6']", count: 1
    names = css_select("form [name^='agent[']").map { |field| field["name"] }
    assert_operator names.index("agent[description]"), :<, names.index("agent[capacity]")
    assert_operator names.index("agent[capacity]"), :<, names.index("agent[model_alias_id]")
  end

  test "the form saves the host's own attributes only when the host names them" do
    Harbor.config.agent_class = "HarborAgentsPagesTest::HostAgent"
    update_agent(capacity: 11)
    assert_redirected_to harbor.agent_path(@writer)
    assert_equal 6, @writer.reload.max_agents, "an attribute the host hasn't named is left out"

    Harbor.config.agent_params = %i[capacity]
    update_agent(capacity: 11)
    assert_equal 11, @writer.reload.max_agents
    update_agent(max_agents: 4, capacity: 12)
    assert_equal 4, @writer.reload.max_agents, "where both set the same thing, Harbor's own field wins"
  end

  test "a host is told when an agent is saved from its form, before it is checked, and at no other time" do
    saves = []
    Harbor.config.agent_edited = lambda do |agent, user|
      saves << [ agent.key, agent.name, agent.changed?, user.name ]
      agent.description = "Edited by #{user.name}."
    end
    update_agent(name: "Wrenna")
    assert_redirected_to harbor.agent_path(@writer)
    assert_equal [ [ "writer", "Wrenna", true, "Sam Settings" ] ], saves
    assert_equal "Edited by Sam Settings.", @writer.reload.description, "what the host set is saved with the rest"

    post harbor.agents_path, params: { agent: { key: "editor", model_alias_id: @alias.id } }
    assert_equal "Edited by Sam Settings.", Harbor::Agent.find_by!(key: "editor").description
    assert_equal 2, saves.size

    update_agent(max_workspaces: 0)
    assert_response :unprocessable_entity
    assert_equal 3, saves.size, "the host hears before the agent is checked"
    update_agent(configuration: "{bad")
    assert_equal 3, saves.size, "a form that couldn't be read is never handed over"

    @writer.update!(name: "Renamed in code")
    Harbor::Agent.create!(key: "imported")
    patch harbor.task_assignment_path("review"), params: { agent_key: "writer" }
    assert_equal 3, saves.size, "only the form's saves are the host's to hear about"
  end

  test "a host's agent class is the one the pages build and find" do
    Harbor.config.agent_class = "HarborAgentsPagesTest::HostAgent"
    post harbor.agents_path, params: { agent: { key: "editor", model_alias_id: @alias.id } }
    assert_redirected_to harbor.agent_path(Harbor::Agent.find_by!(key: "editor"))
    get harbor.agents_path
    assert_select "tr[data-agent]", count: 2
    get harbor.new_agent_path
    assert_select "form[action=?] input[name='agent[key]']", harbor.agents_path
  end

  # --- the switch, the login and the addresses ---

  test "the pages can be switched off; avatars stay, for the other pages that show them" do
    update_agent(avatar: upload)
    Harbor::Setting.set!(:page_agents, "false")
    [ harbor.agents_path, harbor.agents_path(tab: "routing"), harbor.agent_path(@writer), harbor.new_agent_path, harbor.edit_agent_path(@writer) ].each do |path|
      get path
      assert_response :not_found, "#{path} is still served with Agents off"
    end
    post harbor.agents_path, params: { agent: { key: "editor", model_alias_id: @alias.id } }
    assert_response :not_found
    update_agent(name: "Unsaved")
    assert_response :not_found
    patch harbor.context_agents_path, params: { body: "x" }
    assert_response :not_found
    patch harbor.task_assignment_path("review"), params: { agent_key: "writer" }
    assert_response :not_found
    assert_equal [ "Wren", 0, 0 ], [ @writer.reload.name, Harbor::AgentSetting.count, Harbor::TaskAssignment.count ]

    get harbor.avatar_agent_path(@writer)
    assert_response :success
    get "/reports"
    assert_not_includes css_select("[data-harbor-menu] a").map { |a| a.text.strip }, "Agents"
  end

  test "the pages need a login, the avatar included" do
    update_agent(avatar: upload)
    get harbor.avatar_agent_path(@writer)
    etag = response.headers["ETag"]
    delete "/logout"
    [ harbor.agents_path, harbor.agent_path(@writer), harbor.new_agent_path, harbor.edit_agent_path(@writer) ].each do |path|
      get path
      assert_redirected_to "/login"
    end
    get harbor.avatar_agent_path(@writer), headers: { "If-None-Match" => etag }
    assert_redirected_to "/login"
    patch harbor.context_agents_path, params: { body: "x" }
    assert_redirected_to "/login"
    patch harbor.task_assignment_path("review"), params: { agent_key: "writer" }
    assert_redirected_to "/login"
    assert_equal 0, Harbor::AgentSetting.count + Harbor::TaskAssignment.count
  end

  test "the pages live under Harbor's path, and the menu links to them" do
    assert_equal "/factory/agents", harbor.agents_path
    assert_equal "/factory/agents?tab=routing", harbor.agents_path(tab: "routing")
    assert_equal "/factory/agents/#{@writer.id}", harbor.agent_path(@writer)
    assert_equal "/factory/agents/new", harbor.new_agent_path
    assert_equal "/factory/agents/#{@writer.id}/edit", harbor.edit_agent_path(@writer)
    assert_equal "/factory/agents/#{@writer.id}/avatar", harbor.avatar_agent_path(@writer)
    assert_equal "/factory/agents/context", harbor.context_agents_path
    assert_equal "/factory/task_assignments/review", harbor.task_assignment_path("review")
    get "/reports"
    assert_select "[data-harbor-menu] a[href='/factory/agents']", text: "Agents"
  end
end
