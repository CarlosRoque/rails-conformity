module Rails
  module Conformity
    module Providers
      class Base
        def id
          self.class.name.demodulize.underscore
        end

        def call(files:, full: false, progress: nil)
          []
        end
      end
    end
  end
end
