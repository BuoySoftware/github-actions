require_relative "compare"
require_relative "version"

class Release
  def self.prepare(base_ref:, head_ref:)
    new(base_ref:, head_ref:).prepare
  end

  def initialize(base_ref:, head_ref:)
    @base_ref = base_ref
    @head_ref = head_ref
  end

  attr_reader :base_ref, :head_ref

  def prepare
    puts "Version: #{Version.from_ref(compare.head_ref)}"

    puts "Analyzing changes between #{compare.base_ref} and #{compare.head_ref}"

    puts "Pull Requests:"
    compare.pull_requests.each do |pr|
      puts "- ##{pr.number}: #{pr.title}"
      puts "  - Asana Links:"
      pr.asana_links.each do |link|
        puts "    - #{link}"
      end
      puts "  - Jira Tickets:"
      pr.jira_tickets.each do |ticket|
        puts "    - #{ticket}"
      end
    end

    puts "Feature Flags:"
    compare.environment_feature_flags.each do |feature|
      puts "  - #{feature}"
    end

    puts "Jira Projects:"
    jira_projects.each do |jira_project|
      puts "  - #{jira_project}"
    end

    puts "Jira Versions:"
    version.jira_versions.each do |jira_version|
      puts "  - #{jira_version.attrs["self"]}"
    end
  end

  private

  def version
    @version ||= Version.new(compare.head_ref, jira_projects:)
  end

  def compare
    @compare ||= Compare.new(base_ref: base_ref, head_ref: head_ref)
  end

  def jira_projects
    @jira_projects ||= compare.pull_requests.flat_map(&:jira_projects).uniq
  end
end