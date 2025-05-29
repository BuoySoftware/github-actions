class Version
  VERSION_REGEX = /^v(\d+\.\d+)(?:-rc\.\d+)?$/

  def initialize(ref)
    @ref = ref
  end

  attr_reader :ref

  def to_s
    ref.match(VERSION_REGEX)&.[](1)
  end
end