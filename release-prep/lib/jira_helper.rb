require 'jira-ruby'

class JiraHelper
  def self.client
    @client ||= JIRA::Client.new(
      username: ENV.fetch('ATLASSIAN_EMAIL'),
      password: ENV.fetch('ATLASSIAN_API_TOKEN'),
      site: ENV.fetch('ATLASSIAN_URL'),
      context_path: '',
      auth_type: :basic
    )
  end
end 