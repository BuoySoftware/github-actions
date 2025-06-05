# frozen_string_literal: true

class Version
  VERSION_REGEX = /^v(\d+\.\d+)(?:-rc\.?\d+)?$/
  ERROR_MESSAGE = "Invalid version format. Expected format: vX.Y or vX.Y-rc.N"

  def initialize(ref:)
    @ref = ref
    validate_version_format!
  end

  attr_reader :ref

  def name
    "v#{version_number}"
  end

  def number
    version_number.to_f
  end

  private

  def version_number
    ref.match(VERSION_REGEX)[1]
  end

  def validate_version_format!
    return if ref.match?(VERSION_REGEX)

    raise ArgumentError, ERROR_MESSAGE
  end
end
