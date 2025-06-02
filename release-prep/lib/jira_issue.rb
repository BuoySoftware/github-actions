class JiraIssue
  def initialize(ticket:)
    @ticket = ticket
  end

  attr_reader :ticket

  def add_to_jira_version(jira_version:)
    if fix_version_exists?(jira_version)
      puts " - #{ticket} already added to #{jira_version.name}."
    else
      jira_issue.save({
        "fields" => {
          "fixVersions" => existing_fix_versions.map { |fv|
            { "id" => fv["id"] }
          } + [{ "id" => jira_version.attrs["id"] }],
        },
      })
      puts " - Added #{ticket} to #{jira_version.name}"
    end
  end

  private

  def jira_issue
    @jira_issue ||= JiraHelper.client.Issue.find(ticket)
  end

  def fix_version_exists?(jira_version)
    existing_fix_versions.any? { |fv| fv["id"] == jira_version.attrs["id"] }
  end

  def existing_fix_versions
    jira_issue.fields["fixVersions"]
  end
end