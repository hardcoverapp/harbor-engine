require "test_helper"

# The example recipe in examples/environment-recipes, run as Harbor runs a
# recipe's steps, with a stand-in for the `orca` command: a script that
# prints a recipe result and stays running, as `orca serve --recipe-json`
# does. No Orca server is started.
class HarborExampleRecipeTest < ActiveSupport::TestCase
  Script = Harbor::Machines::Script
  EXAMPLES = File.expand_path("../../examples/environment-recipes", __dir__)

  setup do
    @dir = Dir.mktmpdir("harbor-example")
    @orca = File.join(@dir, "orca")
    File.write(@orca, <<~SH)
      #!/bin/sh
      echo "$@" > "#{@dir}/orca.args"
      echo "$ORCA_SERVE_RUNTIME $ORCA_USER_DATA_PATH" > "#{@dir}/orca.env"
      printf '{"schemaVersion":1,"pairingCode":"orca://pair?fake","projectRoot":"#{@dir}"}\\n'
      exec sleep 300
    SH
    File.chmod(0o755, @orca)
    @env = { "ORCA_VM_INSTANCE_ID" => "harbor-1-abcd1234", "ORCA_RECIPE_ID" => "local", "LOCAL_ORCA_PROJECT_ROOT" => @dir,
             "LOCAL_ORCA_STATE_DIR" => File.join(@dir, "state"), "LOCAL_ORCA_BIN" => @orca, "LOCAL_ORCA_PAIRING_ADDRESS" => nil }
  end

  teardown do
    pid = File.read(File.join(@dir, "state/harbor-1-abcd1234/pid")).to_i rescue nil
    (Process.kill("KILL", pid) rescue nil) if pid&.positive?
    FileUtils.remove_entry(@dir)
  end

  def step(name, stdin: nil) = Script.run(File.join(EXAMPLES, "local-orca-#{name}.sh"), chdir: @dir, env: @env, stdin:, timeout: 60)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  test "create starts a server for the instance and prints one result; destroy stops it, with or without that result" do
    created = step("create")
    assert created.ok?
    result = Harbor::Machines::RecipeResult.parse(created.stdout)
    assert_equal [ "orca://pair?fake", @dir ], result.values_at("pairingCode", "projectRoot")
    assert_equal [ "local-orca", "harbor-1-abcd1234" ], result["userData"].values_at("provider", "resourceId")
    pid = File.read(File.join(@dir, "state/harbor-1-abcd1234/pid")).to_i
    assert alive?(pid)
    assert_match(/\Aserve --port \d+ --bind 127\.0\.0\.1 --project-root #{Regexp.escape(@dir)} --recipe-json\n\z/, File.read(File.join(@dir, "orca.args")))
    assert_equal "orcad #{@dir}/state/harbor-1-abcd1234/data\n", File.read(File.join(@dir, "orca.env")), "headless, with a profile of its own"

    again = step("create")
    assert_equal result, Harbor::Machines::RecipeResult.parse(again.stdout), "create is idempotent for an instance id"
    assert_equal pid, File.read(File.join(@dir, "state/harbor-1-abcd1234/pid")).to_i

    # No recipeResult: what Harbor sends after a create that never returned.
    removed = step("destroy", stdin: %({"schemaVersion":1,"mode":"destroy","recipeId":"local","instanceId":"harbor-1-abcd1234"}\n))
    assert removed.ok?
    sleep 0.2
    assert_not alive?(pid)
    assert_not File.exist?(File.join(@dir, "state/harbor-1-abcd1234"))
    assert step("destroy", stdin: %({"instanceId":"harbor-1-abcd1234"}\n)).ok?, "an instance that is gone is gone"
    assert_not step("destroy", stdin: "{}\n").ok?
  end

  test "a server that stops before it is ready fails create and leaves nothing behind" do
    File.write(@orca, "#!/bin/sh\necho 'no licence' >&2\nexit 3\n")
    lines = []
    failed = Script.run(File.join(EXAMPLES, "local-orca-create.sh"), chdir: @dir, env: @env, timeout: 60, on_stderr: ->(line) { lines << line })
    assert_not failed.ok?
    assert_empty failed.stdout
    assert_includes lines, "no licence"
    assert_not File.exist?(File.join(@dir, "state/harbor-1-abcd1234"))
  end
end
