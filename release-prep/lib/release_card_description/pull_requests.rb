require_relative "base"

module ReleaseCardDescription
  class PullRequests < Base
    JIRA_TICKET_REGEX = /[A-Z]+-\d+/
    ASANA_LEGACY_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/\d+}
    ASANA_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/project/\d+/task/\d+}

    def build
      <<~MARKDOWN
        h2. Pull Requests

        #{pull_requests_by_group.map do |group|
          <<~MARKDOWN
            h3. #{group[:group]}
            #{group[:pull_requests].map do |pr|
              " - [##{pr.number}: #{pr.title}|#{pr.html_url}]"
            end.join("\n")}
          MARKDOWN
        end.join("\n\n")}
      MARKDOWN
    end

    private

    def pull_requests_by_group
      %w[Associated Asana Unassociated Dependencies].map do |group_name|
        pull_request_group_hash(group_name)
      end
    end

    def pull_request_group_hash(group_name)
      {
        group: group_name,
        pull_requests: pull_requests_by_group_name(group_name),
      }
    end

    def pull_requests_by_group_name(group_name)
      categorized = categorize_pull_requests
      case group_name
      when "Associated" then categorized[:associated]
      when "Asana" then categorized[:asana]
      when "Unassociated" then categorized[:unassociated]
      when "Dependencies" then categorized[:dependencies]
      else []
      end
    end

    def categorize_pull_requests
      categorized = empty_pull_request_categories
      release.github_assets.commits_by_pull_request.each do |group|
        pull_request, commits = group.values_at(:pull_request, :commits)
        commit_messages = commits.map(&:commit).map(&:message).join("\n")
        category = categorize_single_pull_request(pull_request, commit_messages)
        categorized[category] << pull_request
      end
      categorized
    end

    def empty_pull_request_categories
      {
        associated: [],
        asana: [],
        dependencies: [],
        unassociated: [],
      }
    end

    def categorize_single_pull_request(pull_request, commit_messages)
      if jira_reference?(pull_request, commit_messages)
        :associated
      elsif asana_reference?(pull_request, commit_messages)
        :asana
      elsif pull_request.user.login.match?("dependabot")
        :dependencies
      else
        :unassociated
      end
    end

    def jira_reference?(pull_request, commit_messages)
      [
        commit_messages.match?(JIRA_TICKET_REGEX),
        pull_request.title.match?(JIRA_TICKET_REGEX),
        pull_request.body&.match?(JIRA_TICKET_REGEX),
      ].any?
    end

    def asana_reference?(pull_request, commit_messages)
      [
        pull_request.body&.match?(ASANA_LINK_REGEX),
        pull_request.body&.match?(ASANA_LEGACY_LINK_REGEX),
        commit_messages.match?(ASANA_LINK_REGEX),
        commit_messages.match?(ASANA_LEGACY_LINK_REGEX),
      ].any?
    end
  end
end
