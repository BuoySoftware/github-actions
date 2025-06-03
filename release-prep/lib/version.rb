class Version
  VERSION_REGEX = /^v(\d+\.\d+)(?:-rc\.?\d+)?$/

  def initialize(ref:)
    @ref = ref
  end

  attr_reader :ref

  def name
    "v#{ref.match(VERSION_REGEX)&.[](1)}"
  end

  def number
    "#{ref.match(VERSION_REGEX)&.[](1)}".to_f
  end
end