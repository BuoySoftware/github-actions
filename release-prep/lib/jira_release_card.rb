class JiraReleaseCard
  def self.create(release:)
    new(release:).create
  end

  def initialize(release:)
    @release = release
  end

  attr_reader :release

  def create
    issue = JiraHelper.client.Issue.build
    payload = {
      "fields" => {
        "project" => { "key" => "VERSIONS" },
        "summary" => summary,
        "issuetype" => { "name" => "Version" },
        "description" => description,
        "customfield_10298" => release.version.number,
        "customfield_10297" => { "value" => ENV.fetch("GITHUB_REPO") },
        "customfield_10363" => release_note_link
      },
    }
    issue.save!(payload)
  end

  private

  def summary
    "#{ENV.fetch("GITHUB_REPO")} #{release.version.name}"
  end

  def description
    <<~MARKDOWN
    h1. #{summary}

    ||Version||#{release.version.number}|
    ||Base Ref||#{release.compare.base_ref}|
    ||Head Ref||#{release.compare.head_ref}|
    ||Github Compare||[#{release.compare.base_ref}...#{release.compare.head_ref}|#{release.compare.github_url}]|

    ----

    h2. Issues By Project

    #{issues_by_project.map do |group|
      <<~MARKDOWN
        h3. #{group[:project]}
        #{group[:tickets].map do |ticket|
          " - #{ticket}"
        end.join("\n")}
      MARKDOWN
    end.join("\n\n")}

    #{asana_tasks}

    ----

    h2. Referenced Environment Feature Flags

    ||Environment Feature Flage||Enabled||
    #{release.environment_feature_flags.map do |feature|
      "|#{feature}|false|"
    end.join("\n")}

    ----

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

  def release_note_link
    "#{release.release_note.main_page.dig("_links", "base")}#{release.release_note.main_page.dig("_links", "webui")}"
  end

  def issues_by_project
    release.compare.jira_projects.map do |jira_project|
      {
        project: jira_project,
        tickets: release.pull_requests.select do |pr| 
          pr.jira_projects.include?(jira_project) 
        end.map(&:jira_tickets).flatten.uniq,
      }
    end
  end

  def asana_tasks
    asana_links = release.pull_requests.map(&:asana_links).flatten.uniq

    asana_links.any? ? <<~MARKDOWN : ""
      ----

      h2. Asana Tasks

      #{asana_links.map do |link|
        " - #{link}"
      end.join("\n")}
    MARKDOWN
  end

  def pull_requests_by_group
    associated_pull_requests = []
    unassociated_pull_requests = []
    dependency_pull_requests = []

    release.compare.pull_requests.each do |pr|
      if pr.asana_links.any? || pr.jira_tickets.any?
        associated_pull_requests << pr
      elsif pr.title.match?(/^Bump/i)
        dependency_pull_requests << pr
      else
        unassociated_pull_requests << pr
      end
    end

    [
      {
        group: "Associated",
        pull_requests: associated_pull_requests,
      },
      {
        group: "Unassociated",
        pull_requests: unassociated_pull_requests,
      },
      {
        group: "Dependencies",
        pull_requests: dependency_pull_requests,
      }
    ]
  end
end