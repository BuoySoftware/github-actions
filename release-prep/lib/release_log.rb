class ReleaseLog
  def self.put(release:)
    new(release:).put
  end

  def initialize(release:)
    @release = release
  end

  attr_reader :release

  def put
    puts <<~OUTPUT
      Version: #{release.version.name}

      Pull Requests:
      #{release.pull_requests.map do |pr|
        <<~PR.chomp
          - ##{pr.number}: #{pr.title}
            - Asana Links:
          #{pr.asana_links.map do |link| 
            "  - #{link}"
          end.join("\n")}
            - Jira Tickets:
          #{pr.jira_tickets.map do |ticket|
            "  - #{ticket}"
          end.join("\n")}
        PR
      end.join("\n")}

      Feature Flags:
      #{release.environment_feature_flags.map do |feature|
        "  - #{feature}"
      end.join("\n")}

      Jira Projects:
      #{release.jira_projects.map do |project|
        "  - #{project}"
      end.join("\n")}

      Jira Versions:
      #{release.jira_versions.map do |version|
        "  - #{version.url}"
      end.join("\n")}

      Release Notes:
      Main Page:
        - #{ConfluenceHelper.web_url(webui: release.release_note.main_page.dig("_links", "webui"))}"
      Technical Notes:
      #{release.release_note.technical_notes.map do |note|
        "  - #{ConfluenceHelper.web_url(webui: note.dig("_links", "webui"))}"
      end.join("\n")}
      Deployment Plans:
      #{release.release_note.deployment_plans.map do |plan|
        "  - #{ConfluenceHelper.web_url(webui: plan.dig("_links", "webui"))}"
      end.join("\n")}
    OUTPUT
  end
end