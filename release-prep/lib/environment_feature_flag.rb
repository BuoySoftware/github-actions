class EnvironmentFeatureFlag
  FEATURE_MODULE_REGEX = %r{Feature(::[\w]+)+}.freeze
  UNDERSCORE_REGEX = %r{(?<=[a-z])(?=[A-Z])|::}.freeze

  def self.detect(changes:)
    new(changes:).detect
  end

  def initialize(changes:)
    @changes = changes
  end

  attr_reader :changes

  def detect
    changes.compact.flatten.filter_map do |change|
      feature_module = change.match(FEATURE_MODULE_REGEX)&.to_s
      if feature_module
        feature_module
          .gsub(UNDERSCORE_REGEX, "_")
          .upcase
          .gsub("FEATURE_", "") + "_ENABLED"
      end
    end.uniq
  end
end