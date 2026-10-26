# frozen_string_literal: true

# gobject-introspection -- vendors a rubygems_plugin.rb the real gem doesn't
# ship at all (verified directly: absent from the real 4.3.6 source, and
# absent from a real macOS install of the same version -- confirmed this
# isn't something upstream provides on any platform).
#
# RubyGems loads this plugin for gem commands, not ordinary gem activation.
# The gobject-introspection require-time patch explicitly requires this file
# too, so GTK consumers initialize the cache in their own process. Keep this
# single implementation for both entry points. Retire the cache setup when
# upstream provides relocatable loader discovery for our vendored Windows tree.
#
# Windows-only (whole body is gated on Gem.win_platform?; a no-op everywhere
# else): points FONTCONFIG_FILE/FONTCONFIG_PATH at the vendored fontconfig
# config (Windows has no system fontconfig for GTK/Pango to fall back on --
# also set up in this gem's own dll-path-and-require-abi.rb patch, at
# require time; both firing is redundant in the
# ordinary case but deliberately preserved here to match the original
# reference exactly, not trimmed on a guess that the redundancy is harmless),
# and generates gdk-pixbuf's loaders.cache from a template -- the actual
# vendored install path is only known per-machine at install time, so it
# can't be baked in statically ahead of time.
#
# Cache I/O remains best-effort so a read-only installation does not prevent
# loading the entire GTK stack. Clean packaged image smoke separately requires
# working image decoding; an I/O failure cannot qualify the built bundle.
# Ported from patch-ruby-gnome-macos.sh (2026-07).
{
  file: 'lib/rubygems_plugin.rb',
  marker: 'GDK_PIXBUF_MODULE_FILE',
  content: <<~'RUBY'
    if Gem.win_platform?
      gi_spec = Gem::Specification.find_by_name("gobject-introspection") rescue nil
      if gi_spec
        begin
          vendor_dir = File.join(gi_spec.gem_dir, "vendor", "local")
          fontconfig_file = File.join(vendor_dir, "etc", "fonts", "fonts.conf")
          if File.exist?(fontconfig_file)
            ENV["FONTCONFIG_FILE"] = fontconfig_file
            ENV["FONTCONFIG_PATH"] = File.dirname(fontconfig_file)
          end

          pixbuf_dir = File.join(vendor_dir, "lib", "gdk-pixbuf-2.0", "2.10.0")
          loaders_dir = File.join(pixbuf_dir, "loaders")
          cache_template = File.join(pixbuf_dir, "loaders.cache.in")
          cache_file = File.join(pixbuf_dir, "loaders.cache")
          if File.exist?(cache_template) && File.directory?(loaders_dir)
            template = File.read(cache_template)
            File.write(cache_file, template.gsub("@@MODULEDIR@@") { loaders_dir.tr("\\", "/") })
            ENV["GDK_PIXBUF_MODULE_FILE"] = cache_file if File.exist?(cache_file)
          end
        rescue StandardError
          nil
        end
      end
    end
  RUBY
}
