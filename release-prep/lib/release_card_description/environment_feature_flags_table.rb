require_relative "base"

module ReleaseCardDescription
  class EnvironmentFeatureFlagsTable < Base
    def build
      [
        "h2. Referenced Environment Feature Flags",
        table_header,
        generate_rows,
      ].join("\n")
    end

    private

    def table_header
      "|| Environment Feature Flag || Enabled ||"
    end

    def generate_rows
      release.environment_feature_flags.map do |feature|
        [
          "",
          feature,
          "false",
          "",
        ].join("|")
      end.join("\n")
    end
  end
end
