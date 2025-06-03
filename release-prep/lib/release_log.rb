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
        - #{release.release_note.url}"
      Technical Notes:
      #{release.technical_notes.map do |note|
        "  - #{note.url}"
      end.join("\n")}
      Deployment Plans:
      #{release.deployment_plans.map do |plan|
        "  - #{plan.url}"
      end.join("\n")}
    OUTPUT
  end
end