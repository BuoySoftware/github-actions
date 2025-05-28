class PullRequest
  attr_reader :number, :title, :body, :commit_messages

  def initialize(pr_data, commit_messages:)
    @number = pr_data.number
    @title = pr_data.title
    @body = pr_data.body
    @commit_messages = commit_messages
  end
end
