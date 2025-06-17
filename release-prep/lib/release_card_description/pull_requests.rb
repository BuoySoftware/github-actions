require_relative "base"

module ReleaseCardDescription
  class PullRequests < Base
    JIRA_TICKET_REGEX = /[A-Z]+-\d+/
    ASANA_LEGACY_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/\d+}
    ASANA_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/project/\d+/task/\d+}

    def build
      [
        "h2. Pull Requests",
        pull_request_lists,
      ].join("\n")
    end

    private

    def pull_request_lists
      pull_requests_by_group.map do |group, pull_requests|
        [
          "h3. #{group}",
          pull_requests.map do |pull_request|
            " * [##{pull_request.number}: #{pull_request.title}|#{pull_request.html_url}]"
          end.join("\n"),
        ].join("\n")
      end.join("\n")
    end

    def pull_requests_by_group
      release.github_assets.pull_requests.group_by do |pull_request|
        if [
          pull_request.text.match?(JIRA_TICKET_REGEX),
          pull_request.text.match?(ASANA_LINK_REGEX),
          pull_request.text.match?(ASANA_LEGACY_LINK_REGEX),
        ].any?
          "Associated"
        elsif pull_request.user.login.match?("dependabot")
          "Dependency Updates"
        else
          "Flagged"
        end
      end
    end
  end
end
