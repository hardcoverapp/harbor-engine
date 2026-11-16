require "test_helper"

# Harbor::Identity: an account agents act as. The record keeps the name of
# the variable that holds the token and never the token.
class HarborIdentityTest < ActiveSupport::TestCase
  Identity = Harbor::Identity
  VARIABLE = "HARBOR_TEST_PAT_RELEASE_BOT".freeze
  TOKEN = "ghp_s3cr3tR3l3as3B0tT0k3n0123456789abcd".freeze

  setup do
    [ Harbor::Automation, Harbor::Agent, Identity ].each(&:delete_all)
    @env = ENV.to_h.slice(VARIABLE)
    ENV.delete(VARIABLE)
    @bot = Identity.create!(name: "Release bot", login: "release-bot", token_env: VARIABLE)
  end

  teardown { @env.key?(VARIABLE) ? ENV[VARIABLE] = @env[VARIABLE] : ENV.delete(VARIABLE) }

  test "an identity is a name, an account's login and the variable that holds its token" do
    assert_equal [ "Release bot", "github", "release-bot", VARIABLE ], @bot.reload.values_at(:name, :kind, :login, :token_env)
    assert_equal [ "GitHub", "@release-bot", "Release bot (@release-bot)" ], [ @bot.kind_label, @bot.handle, @bot.label ]
    assert_equal %w[github], Identity::KINDS.keys
  end

  test "a name and a login are needed, each once, whatever their case" do
    assert_not Identity.new(login: "other", token_env: VARIABLE).valid?
    assert_not Identity.new(name: "Other", token_env: VARIABLE).valid?
    assert_not Identity.new(name: "release BOT", login: "other", token_env: VARIABLE).valid?
    twin = Identity.new(name: "Twin", login: "Release-Bot", token_env: VARIABLE)
    assert_not twin.valid?
    assert_includes twin.errors[:login], "has already been taken"
    assert Identity.new(name: "Other", login: "other", token_env: VARIABLE).valid?
  end

  test "a login is written without its @, and reads as a GitHub username" do
    assert_equal "review-bot", Identity.new(login: " @review-bot ").login
    [ "two words", "-leading", "trailing-", "semi;colon", "a/b", "x" * 40 ].each do |login|
      identity = Identity.new(name: "Odd", login:, token_env: VARIABLE)
      assert_not identity.valid?, login
      assert_includes identity.errors[:login], "is a GitHub username: letters, digits and dashes"
    end
    assert Identity.new(name: "One", login: "a", token_env: VARIABLE).valid?
  end

  test "a kind Harbor doesn't know is refused, and none given is GitHub" do
    assert_not Identity.new(name: "Chat", kind: "chat", login: "bot", token_env: VARIABLE).valid?
    assert_equal "github", Identity.create!(name: "Plain", kind: "", login: "plain", token_env: VARIABLE).kind
  end

  test "the variable must be named" do
    identity = Identity.new(name: "Other", login: "other")
    assert_not identity.valid?
    assert_equal [ "Name the environment variable that holds the token, like GITHUB_PAT_RELEASE_BOT." ], identity.errors[:base]
  end

  test "a token typed where the variable is named is refused, and is kept nowhere" do
    [ TOKEN, "github_pat_11ABCDEFG0abcdefghijkl_mnopqrstuvwxyz", "lowercase_name", "TWO WORDS", "1ST", "A=B" ].each do |typed|
      identity = Identity.new(name: "Other", login: "other", token_env: typed)
      assert_not identity.valid?, typed
      assert_equal [ "The token is named by an environment variable, like GITHUB_PAT_RELEASE_BOT, not typed here." ], identity.errors[:base]
      assert_nil identity.token_env, "what was typed is not kept on the record"
      assert_no_match(/#{Regexp.escape(typed)}/, [ identity.inspect, identity.to_json, identity.attributes.to_json, identity.errors.full_messages.to_json ].join)
      assert_not identity.save
    end

    assert_not @bot.update(token_env: TOKEN)
    assert_equal VARIABLE, @bot.reload.token_env, "and an identity that had a variable keeps it"
    assert_no_match(/s3cr3t/, Identity.connection.select_rows("SELECT * FROM harbor_identities").to_json)
  end

  test "a variable's name is taken as written, with the space around it dropped" do
    assert_equal "GITHUB_PAT_X", Identity.new(token_env: " GITHUB_PAT_X\n").token_env
    %w[A _A A1 GITHUB_PAT_RELEASE_BOT].each { |name| assert Identity.new(name: "N", login: "n", token_env: name).valid?, name }
  end

  test "the token is read from the variable when asked, and is nil while it isn't set" do
    assert_nil @bot.token
    assert_not @bot.token_set?
    ENV[VARIABLE] = TOKEN
    assert_equal TOKEN, @bot.token
    assert @bot.token_set?
    ENV[VARIABLE] = ""
    assert_not @bot.token_set?, "an empty variable is not a token"
  end

  test "the token is never part of the record: not in inspect, JSON, attributes or the database" do
    ENV[VARIABLE] = TOKEN
    @bot.token
    @bot.session_env
    shown = [ @bot.inspect, @bot.to_json, @bot.as_json.to_json, @bot.attributes.to_json, @bot.reload.inspect, Identity.all.to_json,
              Identity.connection.select_rows("SELECT * FROM harbor_identities").to_json ].join
    assert_no_match(/s3cr3t/, shown)
    assert_match VARIABLE, shown, "the variable's name is"
  end

  test "an identity whose variable isn't set says which variable, and no more" do
    error = assert_raises(Identity::TokenMissing) { @bot.session_env }
    assert_equal "the identity Release bot (@release-bot) has no token here: #{VARIABLE} isn't set", error.message
  end

  test "a session acting as a GitHub account gets its token under both names and commits under its login" do
    ENV[VARIABLE] = TOKEN
    assert_equal({ "GH_TOKEN" => TOKEN, "GITHUB_TOKEN" => TOKEN,
                   "GIT_AUTHOR_NAME" => "release-bot", "GIT_AUTHOR_EMAIL" => "release-bot@users.noreply.github.com",
                   "GIT_COMMITTER_NAME" => "release-bot", "GIT_COMMITTER_EMAIL" => "release-bot@users.noreply.github.com" },
                 @bot.session_env)
  end

  test "an agent has an identity or none, and an identity knows its agents" do
    writer = Harbor::Agent.create!(key: "writer")
    assert_nil writer.identity
    writer.update!(identity: @bot)
    assert_equal @bot, writer.reload.identity
    assert_equal [ writer ], @bot.agents.to_a
  end

  test "an identity is found by its login, whatever the case" do
    assert_equal @bot, Identity.with_login("Release-Bot")
    assert_equal @bot, Identity.with_login(" release-bot ")
    assert_nil Identity.with_login("someone-else")
    assert_nil Identity.with_login(nil)
  end

  test "a run acts as the identity it names, else as its agent's, else as nobody" do
    reviewer = Identity.create!(name: "Reviewer", login: "review-bot", token_env: "HARBOR_TEST_PAT_REVIEW_BOT")
    Harbor::Agent.create!(key: "writer", identity: @bot)
    Harbor::Agent.create!(key: "bare")

    assert_equal @bot, Identity.for_run(Harbor::Run.new(agent_key: "writer"))
    assert_equal reviewer, Identity.for_run(Harbor::Run.new(agent_key: "writer", acting_as: "review-bot")), "the run's own choice wins"
    assert_nil Identity.for_run(Harbor::Run.new(agent_key: "writer", acting_as: "the-hosts-own-name")),
               "a name that is no identity's gets nothing of Harbor's, not the agent's"
    assert_nil Identity.for_run(Harbor::Run.new(agent_key: "bare"))
    assert_nil Identity.for_run(Harbor::Run.new)
    assert_equal @bot, Identity.for_run(Harbor::Run.new, agent: Harbor::Agent.find_by!(key: "writer")), "the agent can be handed over"
  end

  test "deleting an identity that agents or automations use is refused, saying which" do
    Harbor::Agent.create!(key: "writer", name: "Wren", identity: @bot)
    Harbor::Agent.create!(key: "editor", identity: @bot)
    assert_not @bot.destroy
    assert_equal [ "Release bot is used by the agents editor and Wren. Give them another identity first." ], @bot.errors[:base]
    assert Identity.exists?(@bot.id)

    Harbor::Agent.find_by!(key: "editor").update!(identity: nil)
    Harbor::Automation.create!(key: "tidy", name: "Nightly tidy", kind: "agent", agent_key: "writer", prompt: "Tidy.", run_as: "release-bot")
    @bot.errors.clear
    assert_not @bot.destroy
    assert_equal [ "Release bot is used by the agent Wren and automation Nightly tidy. Give them another identity first." ], @bot.errors[:base]

    Harbor::Agent.update_all(identity_id: nil)
    Harbor::Automation.update_all(run_as: nil)
    assert @bot.destroy
  end
end
