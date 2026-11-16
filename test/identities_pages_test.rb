require "test_helper"

# The Identities tab of the Agents page, and the form behind it: what a site
# with no code of its own gets. An identity is made, given to an agent, seen
# to have its variable set or not, edited and deleted, and a token is never
# typed, stored or shown.
class HarborIdentitiesPagesTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  VARIABLE = "HARBOR_TEST_PAT_RELEASE_BOT".freeze
  TOKEN = "ghp_s3cr3tR3l3as3B0tT0k3n0123456789abcd".freeze

  setup do
    [ Harbor::Automation, Harbor::TaskAssignment, Harbor::AgentDocument, Harbor::Agent, Harbor::Identity, Harbor::ModelChoice,
      Harbor::ModelAlias, Harbor::ModelProvider ].each(&:delete_all)
    Harbor::Automations.reset!
    @env = ENV[VARIABLE]
    ENV.delete(VARIABLE)
    provider = Harbor::ModelProvider.create!(key: "anthropic")
    @alias = Harbor::ModelAlias.create!(name: "Thinking", model_choices_attributes: [ { model_provider: provider, model: "claude-sonnet-5-5" } ])
    @writer = Harbor::Agent.create!(key: "writer", name: "Wren", model_alias: @alias)
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    @env.nil? ? ENV.delete(VARIABLE) : ENV[VARIABLE] = @env
    Harbor::Automations.reset!
  end

  def current_tab = css_select("nav[data-tabs='agents'] a[aria-current=page]").map(&:text)

  # A row's cells as a wide screen shows them: without the label each
  # carries for when they are stacked.
  def identity_row(login)
    css_select("tr[data-identity='#{login}'] td").map do |cell|
      cell = cell.dup
      cell.css("span.block").each(&:remove)
      cell.text.squish
    end
  end

  def logged
    io = StringIO.new
    extra = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(extra)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(extra)
  end

  def bot = Harbor::Identity.create!(name: "Release bot", login: "release-bot", token_env: VARIABLE)

  test "the Agents page has an Identities tab, empty until one is made" do
    get harbor.agents_path
    assert_equal [ "Agents", "Task routing", "Shared context", "Identities" ], css_select("nav[data-tabs='agents'] a").map(&:text)
    get harbor.agents_path(tab: "identities")
    assert_response :success
    assert_equal [ "Identities" ], current_tab
    assert_select "p", text: "No identities yet."
    assert_select "a[href=?]", harbor.new_identity_path, text: "New identity"
    assert_select "tr[data-agent]", count: 0, message: "each tab shows only its own"
  end

  test "a site with no code of its own makes an identity, gives it to an agent, and sees whether its variable is set" do
    get harbor.new_identity_path
    assert_response :success
    assert_select "title", text: "New identity"
    assert_select "form[action=?]", harbor.identities_path do
      assert_select "input[name='identity[name]'][required]"
      assert_select "input[name='identity[login]'][required]"
      assert_select "input[name='identity[token_env]'][required][autocomplete=off]"
      assert_select "input[type=password], textarea", count: 0, message: "there is nowhere to type a token"
      assert_select "select[name='identity[kind]']", count: 0, message: "one kind: nothing to choose"
      assert_select "input[type=submit][value='Save identity']"
    end
    assert_select "p", text: /never typed here and never stored/

    assert_difference "Harbor::Identity.count" do
      post harbor.identities_path, params: { identity: { name: "Release bot", login: "@release-bot", token_env: VARIABLE } }
    end
    assert_redirected_to harbor.agents_path(tab: "identities")
    follow_redirect!
    assert_equal [ "Identity", "Account", "Token variable", "Used by", "Actions" ], css_select("thead th").map { |th| th.text.strip }
    assert_equal [ "Release bot", "@release-bot GitHub", "#{VARIABLE} not set here", "No agent" ],
                 identity_row("release-bot").first(4)
    assert_select "tr[data-identity='release-bot'] [data-token-state=unset]", count: 1

    # Given to an agent on the agent's form.
    identity = Harbor::Identity.find_by!(login: "release-bot")
    get harbor.edit_agent_path(@writer)
    assert_select "label[for=agent_identity_id]", text: "Acts on GitHub as"
    assert_equal [ [ "Nobody", "" ], [ "Release bot (@release-bot)", identity.id.to_s ] ],
                 css_select("select[name='agent[identity_id]'] option").map { |option| [ option.text, option["value"] ] }
    assert_select "select[name='agent[identity_id]'] option[selected]", count: 0
    assert_select "a[href=?]", harbor.agents_path(tab: "identities"), text: "Manage identities"
    patch harbor.agent_path(@writer), params: { agent: { identity_id: identity.id, model_alias_id: @alias.id } }
    assert_redirected_to harbor.agent_path(@writer)
    assert_equal identity, @writer.reload.identity

    # The agent's page and the list say who it acts as.
    follow_redirect!
    assert_equal [ "Acts on GitHub as", "Release bot (@release-bot)" ],
                 [ css_select("[data-agent-identity] dt").text, css_select("[data-agent-identity] dd").text ]
    get harbor.agents_path
    assert_select "tr[data-agent=writer] [data-agent-identity]", text: "as @release-bot"

    # Set where the app runs, the list says so; the token is not on the page.
    ENV[VARIABLE] = TOKEN
    get harbor.agents_path(tab: "identities")
    assert_equal [ "#{VARIABLE} set here", "Wren" ], identity_row("release-bot")[2, 2]
    assert_select "tr[data-identity='release-bot'] a[href=?]", harbor.agent_path(@writer), text: "Wren"
    assert_no_match(/s3cr3t/, response.body)
    get harbor.edit_identity_path(identity)
    assert_select "[data-token-state]", text: "#{VARIABLE} is set here."
    assert_no_match(/s3cr3t/, response.body)
    get harbor.agent_path(@writer)
    assert_no_match(/s3cr3t/, response.body)
  end

  test "an agent with no identity says nothing about one, and can be put back to nobody" do
    get harbor.agent_path(@writer)
    assert_select "[data-agent-identity]", count: 0
    get harbor.agents_path
    assert_select "[data-agent-identity]", count: 0

    @writer.update!(identity: bot)
    get harbor.edit_agent_path(@writer)
    assert_select "select[name='agent[identity_id]'] option[selected]", text: "Release bot (@release-bot)"
    patch harbor.agent_path(@writer), params: { agent: { identity_id: "", model_alias_id: @alias.id } }
    assert_nil @writer.reload.identity
  end

  test "an identity is edited: its name, its login and the variable it names" do
    identity = bot
    get harbor.edit_identity_path(identity)
    assert_response :success
    assert_select "title", text: "Edit Release bot"
    assert_select "form[action=?]", harbor.identity_path(identity) do
      assert_select "input[name='identity[name]'][value='Release bot']"
      assert_select "input[name='identity[login]'][value='release-bot']"
      assert_select "input[name='identity[token_env]'][value=?]", VARIABLE
    end
    assert_select "[data-token-state]", text: "#{VARIABLE} isn't set here: runs as this account won't start."

    patch harbor.identity_path(identity), params: { identity: { name: "Shipping bot", login: "shipping-bot", token_env: "HARBOR_TEST_PAT_SHIPPING" } }
    assert_redirected_to harbor.agents_path(tab: "identities")
    assert_equal "Identity saved. New runs use it.", flash[:notice]
    assert_equal [ "Shipping bot", "shipping-bot", "HARBOR_TEST_PAT_SHIPPING" ], identity.reload.values_at(:name, :login, :token_env)
  end

  test "a token typed where the variable is named is refused, and is not stored, shown again or logged" do
    log = logged do
      assert_no_difference "Harbor::Identity.count" do
        post harbor.identities_path, params: { identity: { name: "Release bot", login: "release-bot", token_env: TOKEN } }
      end
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: "The token is named by an environment variable, like GITHUB_PAT_RELEASE_BOT, not typed here."
    assert_select "input[name='identity[token_env]']" do |fields|
      assert_nil fields.first["value"], "the field comes back empty"
    end
    assert_select "input[name='identity[name]'][value='Release bot']", count: 1, message: "the rest of what was typed stays"
    assert_no_match(/s3cr3t/, response.body)
    assert_match(/Parameters: .*"token_env"\s*=>\s*"\[FILTERED\]"/, log, "the request's parameters are logged without it")
    assert_no_match(/s3cr3t/, log)

    identity = bot
    log = logged { patch harbor.identity_path(identity), params: { identity: { token_env: TOKEN } } }
    assert_response :unprocessable_entity
    assert_equal VARIABLE, identity.reload.token_env
    assert_no_match(/s3cr3t/, response.body + log)

    named = logged { patch harbor.identity_path(identity), params: { identity: { token_env: "HARBOR_TEST_PAT_OTHER" } } }
    assert_match(/"token_env"\s*=>\s*"HARBOR_TEST_PAT_OTHER"/, named, "a variable's name is no secret, and is logged as it is")
  end

  test "what else is wrong with an identity is said on the form" do
    bot
    post harbor.identities_path, params: { identity: { name: "Release bot", login: "two words", token_env: "" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Name has already been taken/
    assert_select "[role=alert]", text: /Login is a GitHub username: letters, digits and dashes/
    assert_select "[role=alert]", text: /Name the environment variable that holds the token/
  end

  test "an identity is deleted, unless an agent still uses it" do
    identity = bot
    @writer.update!(identity:)
    get harbor.agents_path(tab: "identities")
    assert_select "form[action=?] input[name=_method][value=delete]", harbor.identity_path(identity), count: 1

    assert_no_difference "Harbor::Identity.count" do
      delete harbor.identity_path(identity)
    end
    assert_redirected_to harbor.agents_path(tab: "identities")
    assert_equal "Release bot is used by the agent Wren. Give them another identity first.", flash[:alert]

    @writer.update!(identity: nil)
    assert_difference "Harbor::Identity.count", -1 do
      delete harbor.identity_path(identity)
    end
    assert_equal "Release bot deleted.", flash[:notice]
  end

  test "an identity that doesn't exist is not found" do
    get harbor.edit_identity_path(0)
    assert_response :not_found
    delete harbor.identity_path(0)
    assert_response :not_found
  end

  test "an automation's form offers Harbor's identities when the host declares none, and the agent's own" do
    get harbor.new_automation_path
    assert_select "select[name='automation[run_as]']", count: 0, message: "with no identities there is nothing to pick"

    bot
    get harbor.new_automation_path
    assert_select "label[for=automation_run_as]", text: "Runs as"
    assert_equal [ [ "The agent's own identity", "" ], [ "Release bot (@release-bot)", "release-bot" ] ],
                 css_select("select[name='automation[run_as]'] option").map { |option| [ option.text, option["value"] ] }

    Harbor::Automations.identity "badge-7", label: "Badge 7"
    get harbor.new_automation_path
    assert_equal [ [ "Badge 7", "badge-7" ] ], css_select("select[name='automation[run_as]'] option").map { |option| [ option.text, option["value"] ] },
                 "a host's own list is the list"
  end

  test "the identities pages follow the Agents page's switch, need a login, and live under Harbor's path" do
    identity = bot
    assert_equal [ "/factory/identities/new", "/factory/identities/#{identity.id}/edit", "/factory/identities/#{identity.id}",
                   "/factory/agents?tab=identities" ],
                 [ harbor.new_identity_path, harbor.edit_identity_path(identity), harbor.identity_path(identity), harbor.agents_path(tab: "identities") ]

    Harbor::Setting.set!(:page_agents, "false")
    get harbor.new_identity_path
    assert_response :not_found
    post harbor.identities_path, params: { identity: { name: "X", login: "x", token_env: "X" } }
    assert_response :not_found
    delete harbor.identity_path(identity)
    assert_response :not_found
    assert Harbor::Identity.exists?(identity.id)
    Harbor::Setting.delete_all

    delete "/logout"
    get harbor.new_identity_path
    assert_response :redirect
    post harbor.identities_path, params: { identity: { name: "X", login: "x", token_env: "X" } }
    assert_equal 1, Harbor::Identity.count
  end
end
