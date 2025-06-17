require_relative "base"

module ReleaseCardDescription
  class IssuesByProject < Base
    def build
      [
        "h2. Issues By Project",
        generate_lists,
      ].join("\n")
    end

    private

    def generate_lists
      release.jira_assets.issues_by_project.map do |project, issues|
        [
          "h3. #{project.name}",
          issues.map { |issue| " * #{issue.key}" },
        ]
      end
    end
  end
end
