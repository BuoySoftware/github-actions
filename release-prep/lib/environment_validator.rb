class EnvironmentValidator
  REQUIRED_VARIABLES = %w[
    ASANA_PAT
    ASANA_PROJECT_ID
    ASANA_SECTION_ID
    ATLASSIAN_API_TOKEN
    ATLASSIAN_EMAIL
    ATLASSIAN_URL
    CONFLUENCE_RELEASES_SPACE_KEY
    CONFLUENCE_RELEASES_VERSIONS_PARENT_PAGE_ID
    GITHUB_ORG
    GITHUB_PAT
    GITHUB_REPO
  ].freeze

  def self.validate!
    new.validate!
  end

  def validate!
    missing_vars = REQUIRED_VARIABLES.select { |var| ENV[var].nil? || ENV[var].empty? }

    return unless missing_vars.any?

    raise EnvironmentError, <<~ERROR
      The following required environment variables are not set:
      #{missing_vars.map { |var| "  - #{var}" }.join("\n")}
    ERROR
  end

  class EnvironmentError < StandardError; end
end
