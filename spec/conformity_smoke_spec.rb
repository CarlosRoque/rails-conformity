require "spec_helper"

RSpec.describe "rails-conformity" do
  it "exposes its version" do
    expect(Rails::Conformity::VERSION).to eq("0.1.0")
  end

  it "registers a Railtie" do
    expect(Rails::Conformity::Railtie.superclass).to eq(Rails::Railtie)
  end
end
