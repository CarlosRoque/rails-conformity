require_relative "lib/rails/conformity/version"

Gem::Specification.new do |spec|
  spec.name = "rails-conformity"
  spec.version = Rails::Conformity::VERSION
  spec.authors = ["Carlos Roque"]
  spec.summary = "Convention lifecycle engine for Rails: measure, compare, recommend."
  spec.description = "Measures Rails convention conformity, compares against generator output and team baselines, " \
    "and emits deterministic remediation commands. AI proposes; harnesses decide."
  spec.homepage = "https://github.com/carlosr/rails-conformity"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir["lib/**/*", "MIT-LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.1"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.0"
end
