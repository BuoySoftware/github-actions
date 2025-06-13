require_relative "base"

module ReleaseCardDescription
  class FeatureFlagsTable < Base
    def build
      <<~MARKDOWN
        h2. Referenced Environment Feature Flags

        ||Environment Feature Flage||Enabled||
        #{release.environment_feature_flags.map do |feature|
          "|#{feature}|false|"
        end.join("\n")}
      MARKDOWN
    end
  end
end
