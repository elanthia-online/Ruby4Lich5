# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'rbconfig'

# bin/derive_curated_gems_seed.rb resolves closures for the Ruby it runs on.
# These run it in a child Ruby whose RubyGems client raises on first use, so
# nothing reaches the network and the guard is the only thing that can stop it.
RSpec.describe 'bin/derive_curated_gems_seed.rb' do
  root = File.expand_path('../..', __dir__)
  arm_provenance = File.join(root, 'spec/fixtures/curated-gems-seed/aarch64-mingw-ucrt')

  # +local+ emulates the running Ruby's platform.
  def derive(platform, output, local: nil)
    emulate = if local
                "Gem::Platform.singleton_class.define_method(:local) { |*| Gem::Platform.new(#{local.inspect}) }\n" \
                  "Gem.platforms = [Gem::Platform::RUBY, Gem::Platform.local]"
              else
                ''
              end
    stub = <<~RUBY
      #{emulate}
      require 'ruby4lich5/rubygems_client'
      Ruby4Lich5::RubygemsClient.define_method(:initialize) { |*| raise 'network reached' }
      ARGV.replace([#{output.inspect}])
      load #{File.expand_path('../../bin/derive_curated_gems_seed.rb', __dir__).inspect}
    RUBY
    env = { 'GEM_PLATFORM' => platform }
    Open3.capture3(env, RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', stub)
  end

  it 'refuses a non-default platform on a Ruby of another platform, writing nothing' do
    skip 'this is a genuine aarch64-mingw-ucrt Ruby' if Gem::Platform.local.to_s == 'aarch64-mingw-ucrt'
    provenance = -> { Dir.glob('**/*', base: arm_provenance).to_h { |path| [path, File.mtime(File.join(arm_provenance, path))] } }
    before = [File.exist?(arm_provenance), provenance.call]
    Dir.mktmpdir do |directory|
      output = File.join(directory, 'curated-gems.json')
      _out, error, status = derive('aarch64-mingw-ucrt', output)
      expect(status.exitstatus).to eq(1)
      expect(error).to include('requires a genuine aarch64-mingw-ucrt Ruby', 'Nothing was written')
      expect(error).not_to include('network reached')
      expect(File).not_to exist(output)
    end
    expect([File.exist?(arm_provenance), provenance.call]).to eq(before)
  end

  it 'still lets the default x64 row run on a host Ruby of no other platform row' do
    skip 'this is a genuine aarch64-mingw-ucrt Ruby' if Gem::Platform.local.to_s == 'aarch64-mingw-ucrt'
    Dir.mktmpdir do |directory|
      output = File.join(directory, 'curated-gems.json')
      _out, error, status = derive('x64-mingw-ucrt', output)
      expect(status.success?).to be(false)
      expect(error).to include('network reached')
      expect(File).not_to exist(output)
    end
  end

  # An aarch64 Ruby has no precompiled sqlite3, so it would resolve the
  # source gem and mini_portile2 for the x64 row as well.
  it 'refuses the default x64 row on a Ruby of another platform row, writing nothing' do
    Dir.mktmpdir do |directory|
      output = File.join(directory, 'curated-gems.json')
      _out, error, status = derive('x64-mingw-ucrt', output, local: 'aarch64-mingw-ucrt')
      expect(status.exitstatus).to eq(1)
      expect(error).to include('cannot run on a Ruby for aarch64-mingw-ucrt', 'Nothing was written')
      expect(error).not_to include('network reached')
      expect(File).not_to exist(output)
    end
  end

  it 'lets a Ruby of a platform row derive that row' do
    Dir.mktmpdir do |directory|
      output = File.join(directory, 'curated-gems.json')
      _out, error, status = derive('aarch64-mingw-ucrt', output, local: 'aarch64-mingw-ucrt')
      expect(status.success?).to be(false)
      expect(error).to include('network reached')
      expect(File).not_to exist(output)
    end
  end
end
