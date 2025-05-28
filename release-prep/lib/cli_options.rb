require 'optparse'

class CliOptions
  Options = Struct.new(:base_ref, :head_ref, keyword_init: true)

  def self.parse
    options = Options.new
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: release_prep [options]"

      opts.on("--head_ref=HEAD_REF", "Head reference to compare") do |v|
        options.head_ref = v
      end

      opts.on("--base_ref=BASE_REF", "Base reference to compare against") do |v|
        options.base_ref = v
      end
    end

    parser.parse!

    unless options.head_ref && options.base_ref
      puts "Error: Both --head_ref and --base_ref are required"
      puts parser
      exit 1
    end

    options
  end
end 