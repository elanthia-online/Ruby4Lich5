# frozen_string_literal: true

# Release-check probe for the manual release runbook (docs/RELEASING.md),
# shared by two workflow_dispatch checks:
#
# - release-check-older-ruby.yml: on a clean, older RubyInstaller, run Lich's
#   real startup gem check against a candidate manifest, let recovery install
#   the bundle through its detached helper and relaunch, then load every
#   native unit in the relaunched process.
# - release-check-installer-acceptance.yml: on the Ruby a draft installer just
#   installed, run the same check against the live manifest; it must reach the
#   loaded state on the first run, with no repair.
#
# Each run (the first, and any relaunch) writes run-<n>.json under <markers>;
# the run that loads every unit writes result.json, which the workflow waits
# for. The manifest comes from LICH_GEM_MANIFEST_URL when set, otherwise
# Lich's default (the live manifest).
#
#   ruby lich_startup_probe.rb <lich checkout> <markers directory>
require 'json'
require 'fileutils'

lich_dir, markers = ARGV.map { |path| File.expand_path(path) }
FileUtils.mkdir_p(markers)
TEMP_DIR = File.join(markers, 'temp').tap { |dir| FileUtils.mkdir_p(dir) }
LIB_DIR = File.join(lich_dir, 'lib')
run = Dir.glob(File.join(markers, 'run-*.json')).length + 1
marker = File.join(markers, "run-#{run}.json")
record = { 'run' => run, 'pid' => Process.pid, 'ruby' => RUBY_VERSION, 'ruby_bin' => RbConfig.ruby,
           'manifest' => ENV.fetch('LICH_GEM_MANIFEST_URL', nil) }
File.write(marker, JSON.pretty_generate(record))
at_exit { File.write(marker, JSON.pretty_generate(record.merge('exit' => ($!.respond_to?(:status) ? $!.status : ($! ? 1 : 0))))) }

begin
  require File.join(LIB_DIR, 'version.rb')
  require File.join(LIB_DIR, 'gemcheck.rb')
  # A runner has no one to click the consent dialog; approve it here only.
  Lich::GemCheck.singleton_class.send(:define_method, :confirm_recovery_units) { |_units| :approved }
  groups = %i[default gtk profanity]
  Lich::GemCheck.verify!(*groups)
  # Only reached when nothing needed repair: the relaunched run.
  roots = Lich::GemCheck.required_dependencies(groups).map(&:name).sort
  loaded = {}
  # Gems whose require path is not their name.
  require_paths = { 'tzinfo-data' => 'tzinfo/data' }
  roots.each do |name|
    require require_paths.fetch(name, name)
    loaded[name] = Gem.loaded_specs[name]&.version&.to_s
  rescue LoadError => e
    loaded[name] = "LoadError: #{e.message}"
  end
  require 'sqlite3'
  db = SQLite3::Database.new(':memory:')
  db.execute('CREATE TABLE t (v TEXT)')
  db.execute('INSERT INTO t VALUES (?)', ['ok'])
  sqlite_ok = db.get_first_value('SELECT v FROM t') == 'ok'
  ox_ok = Ox.parse('<a><b>1</b></a>').nodes.first.text == '1'
  failed = loaded.select { |_name, version| version.nil? || version.start_with?('LoadError') }
  result = { 'status' => failed.empty? && sqlite_ok && ox_ok ? 'ok' : 'failed', 'ruby' => RUBY_VERSION,
             'openssl' => OpenSSL::VERSION, 'resolv' => Gem.loaded_specs['resolv']&.version&.to_s,
             'zlib' => Zlib::VERSION, 'loaded' => loaded, 'failed' => failed, 'sqlite3' => SQLite3::SQLITE_VERSION,
             'sqlite_query' => sqlite_ok, 'ox_parse' => ox_ok, 'gtk3' => (Gtk::Version::STRING rescue nil) }
  File.write(File.join(markers, 'result.json'), JSON.pretty_generate(result))
rescue SystemExit
  raise
rescue Exception => e # rubocop:disable Lint/RescueException
  record['error'] = "#{e.class}: #{e.message}"
  File.write(File.join(markers, 'result.json'), JSON.pretty_generate('status' => 'error', 'run' => run, 'error' => record['error'],
                                                                     'backtrace' => Array(e.backtrace).first(15)))
  raise
end
