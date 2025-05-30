require_relative "compare"
require_relative "jira_release_card"
require_relative "asana_release_card"
require_relative "jira_version"
require_relative "release_log"
require_relative "release_note"
require_relative "version"

class Release
  def self.prepare(base_ref:, head_ref:)
    new(base_ref:, head_ref:).prepare
  end

  def initialize(base_ref:, head_ref:)
    @compare = Compare.new(base_ref:, head_ref:)
    @version = Version.new(ref: head_ref)
    @pull_requests = compare.pull_requests
    @environment_feature_flags = compare.environment_feature_flags
    @jira_projects = compare.jira_projects
  end

  attr_reader :compare, :environment_feature_flags, :jira_projects, :jira_versions,
    :pull_requests, :release_note, :version

  def prepare
    create_jira_versions
    create_release_note
    create_jira_release_card
    create_asana_release_card
    ReleaseLog.put(release: self)
  end

  private

  def create_jira_versions
    @jira_versions ||= jira_projects.map do |jira_project_name|
      JiraVersion.find_or_create(
        jira_project_name:,
        tickets: jira_tickets_by_project(jira_project_name),
        version:
      )
    end
  end

  def jira_tickets_by_project(jira_project_name)
    compare.pull_requests.flat_map do |pr|
      pr.jira_tickets.select { |ticket| ticket.start_with?(jira_project_name) }
    end.uniq
  end

  def create_release_note
    @release_note ||= ReleaseNote.find_or_create(version)
  end

  def create_jira_release_card
    @jira_release_card ||= JiraReleaseCard.create(release: self)
  end

  def create_asana_release_card
    @asana_release_card ||= AsanaReleaseCard.create(release: self)
  end
end