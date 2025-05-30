require_relative "jira_issue"

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
    puts "Processing #{tickets.count} tickets for #{name}..."
    tickets.each do |ticket|
      JiraIssue.find_or_create(jira_version:, ticket_name: ticket)
    end

    self
  end

  def url
    "#{ENV.fetch('ATLASSIAN_URL')}/projects/#{jira_project_name}/versions/#{jira_version.attrs["id"]}"
  end

  def name
    "#{jira_project_name} #{version.name}"
  end

  private

  def find_or_create_jira_version
    puts "Processing Jira Project: #{name}:"
    if existing_version
      puts "  - #{name} already exists"
      existing_version
    else
      puts "  - Creating #{name}"
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
end