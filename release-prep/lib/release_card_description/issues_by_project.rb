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
              " # #{issue.key}\n" +
              pull_requests_for_issue(issue).map do |pull_request|
                " *# [##{pull_request.number}: #{pull_request.title}|#{pull_request.html_url}]"
              end.join("\n")
            end.join("\n")}
          MARKDOWN
        end.join("\n\n")}
      MARKDOWN
    end

    private

    def pull_requests_for_issue(issue)
      pull_requests_by_issue.detect do |group|
        group[:issue] == issue
      end[:pull_requests]
    end

    def pull_requests_by_issue
      release.jira_assets.issues.map do |issue|
        {
          issue:,
          pull_requests: release.github_assets.pull_requests.select do |pull_request|
            commit_messages = release.github_assets.commits_by_pull_request.detect do |group|
              group[:pull_request] == pull_request
            end[:commits].map(&:commit).map(&:message).join("\n")

            [
              pull_request.title.include?(issue.key),
              pull_request.body&.include?(issue.key),
              commit_messages.include?(issue.key),
            ].any?
          end,
        }
      end
    end
  end
end
