require_relative "asana_release_card"
require_relative "confluence_assets"
require_relative "environment_feature_flags"
require_relative "github_assets"
require_relative "jira_assets"
require_relative "jira_release_card"
require_relative "version"

class Release
  def self.prepare(base_ref:, head_ref:)
    new(base_ref:, head_ref:).prepare
  end

  def initialize(base_ref:, head_ref:)
    @version = Version.new(ref: head_ref)
    @github_assets = GithubAssets.new(base_ref:, head_ref:)
    @jira_assets = JiraAssets.new(github_assets:, version:)
    @confluence_assets = ConfluenceAssets.new(jira_assets:, version:)
  end

  attr_reader :asana_release_card,
    :confluence_assets,
    :github_assets,
    :jira_assets,
    :version

  def prepare
    puts "Preparing release #{version.name}..."
    puts "findings or creating jira project versions..."
    jira_assets.find_or_create_project_versions
    puts "assigning project versions to issues..."
    jira_assets.assign_versions_to_issues
    puts "finding or creating release notes..."
    confluence_assets.find_or_create_version_note
    puts "finding or creating technical notes..."
    confluence_assets.find_or_create_technical_notes
    puts "finding or creating deployment plans..."
    confluence_assets.find_or_create_deployment_plans
    puts "creating or updating jira release card..."
    jira_assets.create_or_update_release_card(release: self)
    puts "creating asana release card..."
    create_asana_release_card
  end

  def environment_feature_flags
    @environment_feature_flags ||= EnvironmentFeatureFlags.detect(changes: github_assets.changes)
  end

  private

  def create_asana_release_card
    @create_asana_release_card ||= AsanaReleaseCard.create(release: self)
  end
end
