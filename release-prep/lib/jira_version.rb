class JiraVersion
  def self.find_or_create(jira_project_name:, tickets:, version:)
    new(jira_project_name:, tickets:, version:).find_or_create
  end

  def initialize(jira_project_name:, tickets:, version:)
    @version = version
    @jira_project_name = jira_project_name
    @tickets = tickets
    @jira_version = find_or_create_jira_version
  end

  attr_reader :jira_project_name, :jira_version, :tickets, :version

  def find_or_create
    tickets.each do |ticket|
      puts "Adding #{ticket} to #{version.name}"
      issue = JiraHelper.client.Issue.find(ticket)
      existing_fix_versions = issue.fields["fixVersions"] || []
      if existing_fix_versions.any? { |fv| fv["id"] == jira_version.attrs["id"] }
        puts "Version #{jira_version.name} already present in fixVersions for issue #{ticket}"
      else
        issue.save({
          "fields" => {
            "fixVersions" => existing_fix_versions.map { |fv|
              { "id" => fv["id"] }
            } + [{ "id" => jira_version.attrs["id"] }],
          },
        })
      end
    end

    self
  end

  def url
    "#{ENV.fetch('ATLASSIAN_URL')}/projects/#{jira_project_name}/versions/#{jira_version.attrs["id"]}"
  end

  private

  def find_or_create_jira_version
    if existing_version
      puts "#{version.name} already exists in project #{jira_project_name}"
      existing_version
    else
      puts "Creating #{version.name} in project #{jira_project_name}"
      create_version
    end
  end

  def jira_project
    @jira_project ||= JiraHelper.client.Project.find(jira_project_name)
  end

  def existing_version
    @existing_version ||= jira_project.versions.find { |v| v.name == version.name }
  end

  def create_version
    jira_version = JiraHelper.client.Version.build
    jira_version.save!(
      'archived' => false,
      'description' => "Release version #{version.name}",
      'name' => version.name,
      'projectId' => jira_project.id,
      'released' => false
    )
    jira_version.fetch
    jira_version
  end

  def add_tickets(jira_version)
    tickets.each do |ticket|
      puts "Adding #{ticket} to #{version.name}"
      issue = JiraHelper.client.Issue.find(ticket)
      existing_fix_versions = issue.fields["fixVersions"] || []
      if existing_fix_versions.any? { |fv| fv["id"] == jira_version.attrs["id"] }
        puts "Version #{jira_version.name} already present in fixVersions for issue #{ticket}"
      else
        issue.save({
          "fields" => {
            "fixVersions" => existing_fix_versions.map { |fv|
              { "id" => fv["id"] }
            } + [{ "id" => jira_version.attrs["id"] }],
          },
        })
      end
    end
  end
end