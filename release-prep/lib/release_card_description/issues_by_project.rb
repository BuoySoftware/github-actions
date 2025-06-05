require_relative "base"

module ReleaseCardDescription
  class IssuesByProject < Base
    def build
      <<~MARKDOWN
        h2. Issues By Project

        #{release.jira_assets.issues_by_project.map do |group|
          project, issues = group.values_at(:project, :issues)

          <<~MARKDOWN
            h3. #{project.name}
            #{issues.map do |issue|
              " - #{issue.key}"
            end.join("\n")}
          MARKDOWN
        end.join("\n\n")}
      MARKDOWN
    end
  end
end 