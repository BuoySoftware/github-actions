class JiraVersion
  def self.find_or_create(jira_project_name:, version:)
    new(jira_project_name:, version:).find_or_create
  end

  def initialize(jira_project_name:, version:)
    @version = version
    @jira_project_name = jira_project_name
  end

  attr_reader :jira_project_name, :version

  def find_or_create
    if existing_version
      puts "#{version.name} already exists in project #{jira_project_name}"
      existing_version
    else
      puts "Creating #{version.name} in project #{jira_project_name}"
      create_version
    end
  end

  private

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