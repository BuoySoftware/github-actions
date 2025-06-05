# frozen_string_literal: true

require_relative "client"

module Jira
  class Project < SimpleDelegator
    def self.find(project_name)
      target = Client.instance.Project.find(project_name)

      new(target)
    end

    def find_or_create_version(name)
      find_version(name) || create_version(name:)
    end

    def find_version(name)
      versions.detect { |v| v.name == name }
    end

    def create_version(name:)
      version = Client.instance.Version.build
      version.save!(
        "archived" => false,
        "description" => "Release version #{name}",
        "name" => name,
        "projectId" => id,
        "released" => false
      )
      version.fetch
      version
    end
  end
end
