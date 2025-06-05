class EnvironmentFeatureFlags
  FEATURE_MODULE_REGEX = /Feature(::[\w]+)+/
  UNDERSCORE_REGEX = /(?<=[a-z])(?=[A-Z])|::/

  def self.detect(changes:)
    puts "Detecting environment feature flag usages..."
    new(changes:).detect
  end

  def initialize(changes:)
    @changes = changes
  end

  def detect
    changes.compact.flatten.filter_map do |change|
      feature_module = change.match(FEATURE_MODULE_REGEX)&.to_s
      if feature_module
        "#{feature_module
          .gsub(UNDERSCORE_REGEX, '_')
          .upcase
          .gsub('FEATURE_', '')}_ENABLED"
      end
    end.uniq
  end

  private

  attr_reader :changes
end
