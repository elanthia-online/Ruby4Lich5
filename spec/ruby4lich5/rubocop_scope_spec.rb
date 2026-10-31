# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'rubocop'
require 'open3'
require 'rbconfig'

RSpec.describe 'RuboCop discovery scope' do
  it 'inspects owned Ruby files without scanning installed gems, generated files or captured upstream source' do
    root = File.expand_path('../..', __dir__)
    owned = %w[lib/app.rb spec/app_spec.rb spec/fixtures/local_owned.rb]
    excluded = %w[vendor/bundle/ruby/4.0.0/gems/dependency/lib/foreign.rb vendor/lich5/reader.rb tmp/generated.rb node_modules/package/generated.rb .git/generated.rb spec/fixtures/lich5-contract/2127/lib/reader.rb]
    Dir.mktmpdir('r4l5-lint-scope') do |directory|
      directory = File.realpath(directory)
      (owned + excluded).each do |path|
        file = File.join(directory, path)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, "# Source discovery control\n")
      end
      config = File.read(File.join(root, '.rubocop.yml')).sub('./.rubocop/cops/ascii_only_source.rb', File.join(root, '.rubocop/cops/ascii_only_source.rb'))
      path = File.join(directory, '.rubocop.yml')
      File.write(path, config)
      # Use a fresh CLI process so RuboCop resolves defaults relative to this
      # fixture, independent of any cached configuration in the test process.
      output, error, status = Open3.capture3(
        { 'RUBYOPT' => nil }, RbConfig.ruby, '-I', $LOAD_PATH.join(File::PATH_SEPARATOR), Gem.bin_path('rubocop', 'rubocop'),
        '--list-target-files', '--cache', 'false', '--config', path, chdir: directory
      )
      expect(status.success?).to be(true), error
      expect(output.lines.map(&:strip)).to match_array(owned)
    end
  end
end
