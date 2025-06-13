require_relative "client"

module Jira
  class Version < SimpleDelegator
    def self.find_by_project_and_name(project_id, name)
      project = Client.instance.Project.find(project_id)
      project.versions.detect { |v| v.name == name }
    end

    def self.create_or_update(project_id:, name:, **options)
      existing_version = find_by_project_and_name(project_id, name)

      if existing_version
        version_instance = new(existing_version)
        version_instance.update(**options) if options.any?
        version_instance
      else
        create(project_id: project_id, name: name, **options)
      end
    end

    def self.create(project_id:, name:, **options)
      version = Client.instance.Version.build

      payload = {
        "archived" => false,
        "description" => "Release version #{name}",
        "name" => name,
        "projectId" => project_id,
        "released" => false,
      }.merge(options.transform_keys(&:to_s))

      version.save!(payload)
      version.fetch

      new(version)
    end

    def update(**options)
      return self if options.empty?

      payload = options.transform_keys(&:to_s)
      save(payload)
      fetch
      self
    end

    def archive
      update(archived: true)
    end

    def release
      update(released: true)
    end

    def id
      attrs["id"]
    end

    def name
      attrs["name"]
    end

    def project_id
      attrs["projectId"]
    end

    def archived?
      attrs["archived"]
    end

    def released?
      attrs["released"]
    end
  end
end
