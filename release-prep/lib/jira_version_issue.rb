class JiraVersionIssue
  def self.find_or_create(jira_version:, ticket_name:)
    new(jira_version:, ticket_name:).find_or_create
  end

  def initialize(jira_version:, ticket_name:)
    @jira_version = jira_version
    @ticket_name = ticket_name
  end

  attr_reader :jira_version, :ticket_name

  def find_or_create
    puts "Processing #{ticket_name} for #{jira_version.name}..."
    issue = JiraHelper.client.Issue.find(ticket_name)
    existing_fix_versions = issue.fields["fixVersions"] || []
      if existing_fix_versions.any? { |fv| fv["id"] == jira_version.attrs["id"] }
        puts " - #{ticket_name} already added to #{jira_version.name}."
      else
        issue.save({
          "fields" => {
            "fixVersions" => existing_fix_versions.map { |fv|
              { "id" => fv["id"] }
            } + [{ "id" => jira_version.attrs["id"] }],
          },
        })
        puts " - Added #{ticket_name} to #{jira_version.name}"
      end
  end

  private

  def version_name
    @version_name ||= jira_version.attrs["name"]
  end
end