# frozen_string_literal: true

require 'ruby4lich5/patch_applier'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

RSpec.describe 'Packaged GdkPixbuf cache initialization' do
  it 'relocates loader paths during an ordinary require without loading RubyGems plugins' do
    Dir.mktmpdir('pixbuf-runtime') do |temp|
      root = File.join(temp, 'installed gems')
      lib = File.join(root, 'lib')
      pixbuf = File.join(root, 'vendor/local/lib/gdk-pixbuf-2.0/2.10.0')
      loaders = File.join(pixbuf, 'loaders')
      FileUtils.mkdir_p([lib, loaders])
      File.write(File.join(loaders, 'pixbufloader_svg.dll'), 'fixture')
      File.write(File.join(pixbuf, 'loaders.cache.in'), "\"@@MODULEDIR@@/pixbufloader_svg.dll\"\n")
      File.write(File.join(lib, 'gobject-introspection.rb'), "require 'glib2'\nrequire \"gobject_introspection.so\"\n")
      Ruby4Lich5::PatchApplier.new.apply_all('gobject-introspection', root)

      # Stub only the Windows/native boundary; execute the generated Ruby entry point.
      driver = <<~'RUBY'
        require 'pathname'
        require 'json'
        module GLib
          def self.prepend_dll_path(*) = nil
        end
        def Gem.win_platform? = true
        root = ARGV.fetch(0)
        Gem::Specification.define_singleton_method(:find_by_name) { |*| Struct.new(:gem_dir).new(root) }
        $LOADED_FEATURES << 'glib2.rb'
        abi = RUBY_VERSION.split('.').first(2).join('.')
        $LOADED_FEATURES << "gobject-introspection/#{abi}/gobject_introspection.so"
        ENV.delete('GDK_PIXBUF_MODULE_FILE')
        require 'gobject-introspection'
        cache = ENV['GDK_PIXBUF_MODULE_FILE']
        puts JSON.generate(cache: cache, contents: cache && File.read(cache))
      RUBY
      output, status = Open3.capture2e(Gem.ruby, '-I', lib, '-e', driver, root)
      expect(status).to be_success, output
      result = JSON.parse(output)
      expect(result['cache']).to eq(File.join(pixbuf, 'loaders.cache'))
      expect(result['contents']).to eq("\"#{loaders}/pixbufloader_svg.dll\"\n")
    end
  end
end
