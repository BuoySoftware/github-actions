require "jira-ruby"
require "singleton"

module Jira
  class Client < SimpleDelegator
    include Singleton

    def initialize
      jira_client = JIRA::Client.new(
        username: ENV.fetch("ATLASSIAN_EMAIL"),
        password: ENV.fetch("ATLASSIAN_API_TOKEN"),
        site: ENV.fetch("ATLASSIAN_URL"),
        context_path: "",
        auth_type: :basic
      )

      super(jira_client)
    end
  end
end
