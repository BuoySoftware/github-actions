require_relative "base"

module ReleaseCardDescription
  class AsanaTasks < Base
    ASANA_LEGACY_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/\d+}
    ASANA_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/project/\d+/task/\d+}

    def build
      prs_by_asana_link = jira_asana_prs_by_link
      prs_by_asana_link.any? ? asana_tasks_markdown(prs_by_asana_link) : ""
    end

    private

    def jira_asana_prs_by_link
      asana_links_from_pull_requests.map { |link| jira_asana_link_group(link) }
    end

    def asana_links_from_pull_requests
      release.github_assets.pull_requests.map(&:body).flat_map do |body|
        [
          *body&.scan(ASANA_LINK_REGEX),
          *body&.scan(ASANA_LEGACY_LINK_REGEX),
        ]
      end.uniq
    end

    def jira_asana_link_group(link)
      {
        link: link,
        prs: release.github_assets.pull_requests.select { |pr| pr.body&.include?(link) },
      }
    end

    def asana_tasks_markdown(prs_by_asana_link)
      <<~MARKDOWN
        h2. Asana Tasks

        #{prs_by_asana_link.map { |group| asana_task_group_markdown(group) }.join("\n")}
      MARKDOWN
    end

    def asana_task_group_markdown(group)
      [
        " # #{group[:link]}",
        *group[:prs].map { |pr| " *# [##{pr.number}: #{pr.title}|#{pr.html_url}]" },
      ].join("\n")
    end
  end
end
