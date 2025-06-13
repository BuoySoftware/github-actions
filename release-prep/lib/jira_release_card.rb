require_relative "jira/issue"
require_relative "release_card_description/header"
require_relative "release_card_description/metadata_table"
require_relative "release_card_description/issues_by_project"
require_relative "release_card_description/asana_tasks"
require_relative "release_card_description/feature_flags_table"
require_relative "release_card_description/pull_requests"

class JiraReleaseCard
  ASANA_LEGACY_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/\d+}
  ASANA_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/project/\d+/task/\d+}
  JIRA_TICKET_REGEX = /[A-Z]+-\d+/

  def self.create_or_update(release:)
    new(release:).create_or_update
  end

  def initialize(release:)
    @release = release
  end

  attr_reader :release

  def create_or_update
    if existing_release_card
      puts "Release card found: #{existing_release_card.attrs['key']}"
      existing_release_card.save(payload)
      existing_release_card
    else
      puts "Creating release card: #{summary}"
      Jira::Issue.create(payload)
    end
  end

  private

  def existing_release_card
    @existing_release_card ||= Jira::Issue.find_by_summary(summary)
  end

  def payload
    {
      "fields" => {
        "project" => { "key" => "VERSIONS" },
        "summary" => summary,
        "issuetype" => { "name" => "Version" },
        "description" => description,
        "customfield_10298" => release.version.number,
        "customfield_10297" => { "value" => ENV.fetch("GITHUB_REPO") },
        "customfield_10363" => release.confluence_assets.version_note.url,
      },
    }
  end

  def summary
    "#{ENV.fetch('GITHUB_REPO')} #{release.version.name}"
  end

  def description
    [
      ReleaseCardDescription::Header.build(release: release),
      ReleaseCardDescription::MetadataTable.build(release: release),
      ReleaseCardDescription::IssuesByProject.build(release: release),
      ReleaseCardDescription::AsanaTasks.build(release: release),
      ReleaseCardDescription::FeatureFlagsTable.build(release: release),
      ReleaseCardDescription::PullRequests.build(release: release),
    ].join("\n\n")
  end
end
