require_relative "base"

module ReleaseCardDescription
  class ReleaseNotesByFeatureFlag < Base
    def build
      [
        "h2. Release Notes By Feature Flag",
        generate_tables,
      ].join("\n")
    end

    private

    def generate_tables
      release.jira_assets.issues_by_project.map do |project, issues|
        [
          "h3. #{project.name}",
          table_header,
          generate_rows(issues),
        ].join("\n")
      end.join("\n\n")
    end

    def table_header
      "|| Feature Flag || Issues || Release Notes ||"
    end

    def generate_rows(issues)
      issues.group_by(&:feature_flag).map do |feature_flag, issues|
        [
          "",
          feature_flag || "N/A",
          issues.map { |issue| "* [#{issue.key}|#{issue.url}]" }.join("\n"),
          issues.map { |issue| "* #{issue.release_notes}" }.join("\n"),
          "",
        ].join("|")
      end.join("\n")
    end
  end
end
