require "test_helper"

# Environment recipes as the config file declares them: what is read, and
# what is refused with a message that says what is wrong.
class HarborEnvironmentRecipesTest < ActiveSupport::TestCase
  include HarborTestConfig

  Recipes = Harbor::EnvironmentRecipes

  setup do
    @config = Harbor.config.config_file
    @dir = Dir.mktmpdir("harbor-config")
    Harbor.config.config_file = File.join(@dir, "harbor.yml")
    Recipes.reset!
  end

  teardown do
    Harbor.config.config_file = @config
    Harbor::ConfigFile.reload!
    Recipes.reset!
    FileUtils.remove_entry(@dir)
  end

  def write(text)
    File.write(Harbor.config.config_file, text)
    Harbor::ConfigFile.reload!
  end

  test "a site that declares none has none, and a missing file is not a mistake" do
    assert_equal [], Recipes.all
    assert_empty Recipes.problems
    write("databases: {}\n")
    assert_equal [], Recipes.all
    assert_not Recipes.any?
  end

  test "a recipe is read with orca.yaml's keys and meanings" do
    write(<<~YAML)
      environment_recipes:
        aws-sandbox:
          name: AWS sandbox
          create: ./scripts/orca-vm/aws-create.sh
          suspend: ./scripts/orca-vm/aws-suspend.sh
          resume: ./scripts/orca-vm/aws-resume.sh
          destroy: ./scripts/orca-vm/aws-destroy.sh
          timeout_seconds: { create: 1800, destroy: 120 }
        fixed-host:
          create: bash ./scripts/orca-vm/host.sh --fast
          destroy: none
          timeoutSeconds: 60
        <%= "from-erb" %>:
          command: ./old-create.sh
          cleanup: ./old-destroy.sh
    YAML
    sandbox, host, legacy = Recipes.all
    assert_equal [ "aws-sandbox", "AWS sandbox", "./scripts/orca-vm/aws-create.sh", "./scripts/orca-vm/aws-destroy.sh",
                   "./scripts/orca-vm/aws-suspend.sh", "./scripts/orca-vm/aws-resume.sh" ],
                 [ sandbox.id, sandbox.name, sandbox.create, sandbox.destroy, sandbox.suspend, sandbox.resume ]
    assert_equal [ 1800, 120, nil ], [ sandbox.timeout("create"), sandbox.timeout(:destroy), sandbox.timeout("resume") ]
    assert_not sandbox.destroy_disabled?

    assert_equal [ "fixed-host", "fixed-host", nil ], [ host.id, host.name, host.destroy ], "a recipe with no name is called by its id"
    assert host.destroy_disabled?, "destroy: none removes nothing"
    assert_equal [ 60, 60 ], [ host.timeout("create"), host.timeout("destroy") ], "one number is every step's limit"

    assert_equal [ "from-erb", "./old-create.sh", "./old-destroy.sh" ], [ legacy.id, legacy.create, legacy.destroy ], "the legacy keys still map"
    assert_equal sandbox, Recipes.find("aws-sandbox")
    assert_nil Recipes.find("nope")
    assert_empty Recipes.problems
  end

  test "a mistake is refused, naming the file, the recipe and what is wrong" do
    {
      "environment_recipes: [a, b]\n" => /harbor\.yml: environment_recipes must be a mapping/,
      "environment_recipes:\n  bad id: { create: ./c.sh, destroy: none }\n" => /environment_recipes\.bad id: a recipe's id uses letters, numbers, dots, dashes and underscores/,
      "environment_recipes:\n  box: ./create.sh\n" => /environment_recipes\.box: must be a mapping/,
      "environment_recipes:\n  box: { destroy: ./d.sh }\n" => /environment_recipes\.box: needs create:, the command that starts a machine/,
      "environment_recipes:\n  box: { create: ./c.sh }\n" => /environment_recipes\.box: needs destroy:, the command that removes the machine \(or destroy: none/,
      "environment_recipes:\n  box: { create: ./c.sh, destroy: none, creat: ./x.sh }\n" => /environment_recipes\.box: unknown key creat \(expected name, create, suspend, resume, destroy, timeout_seconds\)/,
      "environment_recipes:\n  box: { create: [a], destroy: none }\n" => /environment_recipes\.box: create must be a command/,
      "environment_recipes:\n  box: { create: ./c.sh, destroy: none, suspend: ./s.sh }\n" => /suspend and resume go together/,
      "environment_recipes:\n  box: { create: ./c.sh, command: ./c.sh, destroy: none }\n" => /give create or command, not both/,
      "environment_recipes:\n  box: { create: ./c.sh, destroy: none, timeout_seconds: 0 }\n" => /timeout_seconds for create must be a whole number of seconds from 1 to 86400, not 0/,
      "environment_recipes:\n  box: { create: ./c.sh, destroy: none, timeout_seconds: { create: soon } }\n" => /timeout_seconds for create must be a whole number.*not "soon"/,
      "environment_recipes:\n  box: { create: ./c.sh, destroy: none, timeout_seconds: { build: 5 } }\n" => /timeout_seconds: unknown step build/,
      "environment_recipes:\n  box: { create: ./c.sh, destroy: none, checkoutMode: provisioned-root }\n" => /checkoutMode: provisioned-root is not supported: it needs a recipe that connects over SSH/,
      "environment_recipes:\n  box: { create: ./c.sh, destroy: none }\n  box: { create: ./d.sh, destroy: none }\n" => /environment_recipes\.box appears twice/
    }.each do |text, message|
      write(text)
      Recipes.reset!
      error = assert_raises(Recipes::Error, text) { Recipes.all }
      assert_match message, error.message
      assert_match message, Recipes.problems.first
    end
  end

  test "a recipe says what is wrong with its scripts on disk: missing, or not executable" do
    FileUtils.mkdir_p(File.join(@dir, "scripts"))
    File.write(File.join(@dir, "scripts/create.sh"), "#!/bin/sh\n")
    File.write(File.join(@dir, "scripts/destroy.sh"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(@dir, "scripts/destroy.sh"))
    write("environment_recipes:\n  box: { create: ./scripts/create.sh --fast, destroy: ./scripts/destroy.sh }\n  gone: { create: ./scripts/nope.sh, destroy: none }\n  path: { create: bash -c true, destroy: none }\n")
    box, gone, path = Recipes.all

    assert_equal [ "create: ./scripts/create.sh is not executable (chmod +x)" ], box.script_problems(root: @dir)
    File.chmod(0o755, File.join(@dir, "scripts/create.sh"))
    assert_empty box.script_problems(root: @dir)
    assert_equal [ "create: ./scripts/nope.sh is not there" ], gone.script_problems(root: @dir)
    assert_empty path.script_problems(root: @dir), "a command found on the PATH is not looked for"
  end
end
