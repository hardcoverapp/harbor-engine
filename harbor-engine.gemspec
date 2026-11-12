require_relative "lib/harbor/version"

Gem::Specification.new do |spec|
  # "harbor" was taken on RubyGems in 2009. The code's namespace is still Harbor.
  spec.name        = "harbor-engine"
  spec.version     = Harbor::VERSION
  spec.authors     = [ "Hardcover" ]
  spec.summary     = "Runs agent work: workflows, runs, runtimes, agents and models."
  spec.homepage    = "https://github.com/hardcoverapp/harbor-engine"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) { Dir["{app,config,db,lib}/**/*", "CHANGELOG.md", "LICENSE", "README.md"] }

  spec.add_dependency "rails", ">= 8.1"

  spec.add_dependency "marcel", ">= 1.0"
end
