module ReleaseCardDescription
  class Base
    def self.build(release:)
      new(release:).build
    end

    def initialize(release:)
      @release = release
    end

    def build
      raise NotImplementedError, "Subclass must implement build"
    end

    private

    attr_reader :release
  end
end