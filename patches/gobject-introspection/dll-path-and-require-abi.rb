# frozen_string_literal: true

# gobject-introspection -- vendored-DLL path + typelib path + fontconfig
# setup + ABI-qualified require.
#
# Same GLib.prepend_dll_path shape as glib2's equivalent patch, plus:
# - GI_TYPELIB_PATH pointing at the vendored typelib directory (this gem
#   bundles *every* GI-stack gem's .typelib files under its own
#   vendor/local/lib/girepository-1.0/, confirmed directly against a real
#   built gem -- Atk-1.0.typelib et al. are genuinely packaged). Missing
#   until 2026-07-07: found via a real clean-machine smoke-test failure
#   (GObjectIntrospection::RepositoryError::TypelibNotFound for Atk when
#   requiring gtk3), not by inspection -- the build job sets GI_TYPELIB_PATH
#   as a *build-time-only* environment variable that never made it into the
#   shipped gem's own require-time code, so a genuinely clean machine (no
#   MSYS2, nothing pre-setting the env var) had no way to find the
#   typelibs even though they were correctly packaged all along.
# - FONTCONFIG_PATH/FONTCONFIG_FILE pointing at the vendored fontconfig
#   config, since Windows has no system fontconfig for GTK/Pango's font
#   rendering to fall back on.
#
# Deliberately does NOT port the original PowerShell's separate
# GObjectIntrospection.prepend_typelib_path(...) argument rewrite -- verified
# directly against the real 4.3.6 source that no such *call* exists anywhere
# in this gem (only the method definition does); that rewrite was already
# dead code, matching nothing, before this patch existed. GI_TYPELIB_PATH is
# a different, real mechanism: the standard environment variable libgirepository
# itself (the C library) reads to extend its typelib search path, independent
# of that dead Ruby-level method.
# Ported from patch-ruby-gnome-macos.sh (2026-07), which patches an
# already-installed gem in place; here the same anchor + exact-count
# assertion applies to freshly extracted build source instead.
{
  file: 'lib/gobject-introspection.rb',
  marker: 'GLib.prepend_dll_path(vendor_dir + "bin")',
  steps: [
    {
      old: 'require "gobject_introspection.so"',
      new: [
        'base_dir = Pathname.new(__FILE__).dirname.dirname.expand_path',
        'vendor_dir = base_dir + "vendor" + "local"',
        'GLib.prepend_dll_path(vendor_dir + "bin")',
        '',
        'typelib_path = vendor_dir + "lib" + "girepository-1.0"',
        'if typelib_path.exist?',
        '  ENV["GI_TYPELIB_PATH"] = [typelib_path.to_s, ENV["GI_TYPELIB_PATH"]].compact.join(";")',
        'end',
        '',
        'fontconfig_path = vendor_dir + "etc" + "fonts"',
        'fonts_conf = fontconfig_path + "fonts.conf"',
        'if fontconfig_path.exist? && fonts_conf.exist?',
        '  ENV["FONTCONFIG_PATH"] = fontconfig_path.to_s',
        '  ENV["FONTCONFIG_FILE"] = fonts_conf.to_s',
        'end',
        '',
        # RubyGems plugins are not loaded by ordinary gem activation. Run the
        # shared Windows cache setup before loading the introspection extension.
        'require_relative "rubygems_plugin"',
        '',
        'major, minor, _ = RUBY_VERSION.split(/\./)',
        # rubocop:disable Lint/InterpolationCheck -- deliberately literal: this
        # text is written into the patched gobject-introspection.rb,
        # interpolated by *it* at load time, not by this patch definition now.
        'require "gobject-introspection/#{major}.#{minor}/gobject_introspection.so"'
        # rubocop:enable Lint/InterpolationCheck
      ].join("\n"),
      count: 1
    }
  ]
}
