# frozen_string_literal: true

require 'tmpdir'
require 'base64'
require_relative 'smoke_contract'

module Ruby4Lich5
  # Shared acceptance for factory, baked installer and recovered runtimes.
  class RuntimeSmoke
    def self.run!(lock)
      contract = SmokeContract.for_lock(lock)
      contract.fetch('roots').each do |entry|
        name, version = entry.values_at('name', 'version')
        Gem::Specification.find_by_name(name, "= #{version}").activate
        entry.fetch('requires').each { |path| require path }
        raise "smoke activated the wrong #{name} version" unless Gem.loaded_specs.fetch(name).version.to_s == version
      end
      return true unless contract.fetch('gtk')

      Gtk.init
      spec = Gem::Specification.find_by_name('gobject-introspection')
      expected = File.join(spec.full_gem_path, 'vendor/local/etc/fonts/fonts.conf')
      unless ENV['FONTCONFIG_FILE'] && File.expand_path(ENV['FONTCONFIG_FILE']) == File.expand_path(expected) && File.file?(expected)
        raise 'packaged Fontconfig file is missing or points outside the selected runtime'
      end
      loaders = File.join(spec.full_gem_path, 'vendor/local/lib/gdk-pixbuf-2.0/2.10.0/loaders')
      raise 'packaged SVG loader is missing' if Dir.glob(File.join(loaders, '*svg*.dll')).empty?

      Dir.mktmpdir('runtime image smoke ') do |directory|
        File.write(File.join(directory, 'sample.svg'), '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1" fill="red"/></svg>')
        File.binwrite(File.join(directory, 'sample.png'), Base64.strict_decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC'))
        %w[png svg].each do |format|
          image = GdkPixbuf::Pixbuf.new(file: File.join(directory, "sample.#{format}"))
          raise "unexpected #{format} image dimensions" unless image.width == 1 && image.height == 1
        end
      end
      true
    end
  end
end
