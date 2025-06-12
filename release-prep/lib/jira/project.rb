require_relative "client"

module Jira
  class Project < SimpleDelegator
    def self.find(project_name)
      target = Client.instance.Project.find(project_name)

      new(target)
    end
  end
end
