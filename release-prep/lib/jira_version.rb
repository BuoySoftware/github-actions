require_relative "./jira/issue"
require_relative "./jira/project"

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
      Jira::Issue.find(ticket).add_to_version(jira_version)
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
    @jira_project ||= Jira::Project.find(jira_project_name)
  end

  def existing_version
    @existing_versino ||= jira_project.find_version(version.name)
  end

  def create_version
    @jira_version ||= jira_project.create_version(name: version.name)
  end
end