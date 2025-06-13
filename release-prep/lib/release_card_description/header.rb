require_relative "base"

module ReleaseCardDescription
  class Header < Base
    def build
      "h1. #{summary}"
    end

    private

    def summary
      "#{ENV.fetch('GITHUB_REPO')} #{release.version.name}"
    end
  end
end
