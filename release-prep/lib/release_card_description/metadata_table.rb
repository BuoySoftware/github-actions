require_relative "base"

module ReleaseCardDescription
  class MetadataTable < Base
    def build
      <<~MARKDOWN
        ||Version||#{release.version.name}|
        ||Base Ref||#{release.github_assets.base_ref}|
        ||Head Ref||#{release.github_assets.head_ref}|
        ||Github Compare||[#{release.github_assets.base_ref}...#{release.github_assets.head_ref}|#{release.github_assets.compare_url}]|
        ||Project Versions||#{project_versions}|
      MARKDOWN
    end

    private

    def project_versions
      release.jira_assets.versions_by_project.map do |group|
        project, version = group.values_at(:project, :version)
        url = "#{ENV.fetch('ATLASSIAN_URL')}/projects/#{project.key}/versions/#{version.attrs['id']}"

        "[#{project.key}|#{url}]"
      end.join("\n")
    end
  end
end 