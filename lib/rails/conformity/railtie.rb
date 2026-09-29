require "active_support/core_ext/module/delegation"
require "rails/railtie"

module Rails
  module Conformity
    class Railtie < ::Rails::Railtie
      rake_tasks do
        load File.expand_path("../../tasks/conformity_tasks.rake", __dir__)
      end
    end
  end
end
