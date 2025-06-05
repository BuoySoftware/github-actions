# frozen_string_literal: true

require_relative "release_note"

module ReleaseNotes
  class DeploymentPlan < ReleaseNote
    TEMPLATE = <<~HTML
      <div>
        <h1>Rollout</h1>
        <h1>Rollback</h1>
      </div>
    HTML
  end
end
