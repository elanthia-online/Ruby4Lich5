# frozen_string_literal: true

require 'ruby4lich5/patch_applier'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

RSpec.describe 'Packaged GdkPixbuf cache initialization' do
  [
    ['creates a missing cache during ordinary require', :missing, false],
    ['reuses a matching cache when writes are denied', :matching, true],
    ['refreshes a stale cache after relocation', :stale, false],
    ['does not select a stale cache when writes are denied', :stale, true],
    ['loads without selecting a missing cache when writes are denied', :missing, true]
  ].each do |description, initial_cache, deny_write|
    it description do
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
        cache_file = File.join(pixbuf, 'loaders.cache')
        expected = "\"#{loaders}/pixbufloader_svg.dll\"\n"
        initial_contents = initial_cache == :matching ? expected : 'old installation path'
        File.write(cache_file, initial_contents) unless initial_cache == :missing

        # Execute the generated entry point with Windows/native boundaries stubbed.
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
          # Simulate write denial portably; all reads and successful writes remain real.
          if ARGV.fetch(1) == 'true'
            cache_file = File.join(root, 'vendor/local/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache')
            original_write = File.method(:write)
            File.define_singleton_method(:write) do |path, *args|
              raise Errno::EACCES, path if path == cache_file
              original_write.call(path, *args)
            end
          end
          ENV.delete('GDK_PIXBUF_MODULE_FILE')
          require 'gobject-introspection'
          cache = ENV['GDK_PIXBUF_MODULE_FILE']
          puts JSON.generate(cache: cache, contents: cache && File.read(cache))
        RUBY
        output, status = Open3.capture2e(Gem.ruby, '-I', lib, '-e', driver, root, deny_write.to_s)
        expect(status).to be_success, output
        result = JSON.parse(output)
        if deny_write && initial_cache != :matching
          expect(result).to eq('cache' => nil, 'contents' => nil)
          expect(File.read(cache_file)).to eq(initial_contents) if initial_cache == :stale
          expect(File.exist?(cache_file)).to be(false) if initial_cache == :missing
        else
          expect(result).to eq('cache' => cache_file, 'contents' => expected)
        end
      end
    end
  end
end
