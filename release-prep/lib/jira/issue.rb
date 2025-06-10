require_relative "client"

module Jira
  class Issue < SimpleDelegator
    def self.create(payload)
      target = Client.instance.Issue.build
      target.save!(payload)
      target.fetch

      new(target)
    end

    def self.find(key)
      target = Client.instance.Issue.find(key)

      new(target)
    end

    def self.find_by_summary(summary)
      targets = Client.instance.Issue.jql(
        "summary ~ \"#{summary}\" ORDER BY created DESC"
      )

      return unless targets.any?

      new(targets.first)
    end

    def pre_deploy_instructions
      attrs["fields"]["customfield_10859"]
    end

    def post_deploy_instructions
      attrs["fields"]["customfield_10858"]
    end

    def add_to_version(version)
      save({
        "fields" => {
          "fixVersions" => existing_fix_versions.map do |fv|
            { "id" => fv["id"] }
          end + [{ "id" => version.attrs["id"] }],
        },
      })
    end

    def key
      attrs["key"]
    end

    def url
      "#{ENV.fetch('ATLASSIAN_URL')}/browse/#{key}"
    end

    private

    def existing_fix_versions
      fields["fixVersions"]
    end

    def fix_version_exists?(version)
      existing_fix_versions.any? { |fv| fv["id"] == version.attrs["id"] }
    end
  end
end
