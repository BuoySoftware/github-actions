require_relative "jira_helper"

class Version
  VERSION_REGEX = /^v(\d+\.\d+)(?:-rc\.\d+)?$/

  def self.from_ref(ref)
    new(ref)
  end

  def initialize(ref)
    @ref = ref
  end

  attr_reader :ref

  def name
    "v#{ref.match(VERSION_REGEX)&.[](1)}"
  end
end