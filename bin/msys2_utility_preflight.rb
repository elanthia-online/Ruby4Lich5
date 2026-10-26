# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

# Run under the downloaded RubyInstaller, after MSYS2_PATH is set by the workflow.
# Keep a transcript even if selection or executable startup fails.
log_path = ARGV.fetch(0)
FileUtils.mkdir_p(File.dirname(log_path))
File.open(log_path, 'w') do |log|
  say = lambda do |message|
    puts message
    log.puts message
    log.flush
  end
  failures = []
  run = lambda do |*command|
    say.call("COMMAND #{command.inspect}")
    stdout, stderr, status = Open3.capture3(*command)
    say.call(stdout) unless stdout.empty?
    say.call(stderr) unless stderr.empty?
    say.call("EXIT #{status.exitstatus.inspect}")
    failures << command.inspect unless status.success?
    stdout
  rescue SystemCallError => e
    say.call("STARTUP ERROR #{e.class}: #{e.message}")
    failures << command.inspect
    ''
  end

  begin
    require 'ruby_installer/runtime'
    RubyInstaller::Runtime.enable_msys_apps(for_gem_install: true, if_no_msys: :raise)
    expected = ENV.fetch('MSYS2_ROOT')
    selected = RubyInstaller::Runtime.msys2_installation.msys_path
    say.call("Expected MSYS2 root: #{expected}")
    say.call("RubyInstaller selected MSYS2 root: #{selected}")
    normalize = ->(path) { File.expand_path(path.tr('\\', '/')).downcase }
    unless normalize.call(expected) == normalize.call(selected)
      raise "RubyInstaller selected a different MSYS2 installation"
    end

    tools = %w[make sh uname cp rm]
    tools.each do |tool|
      found = run.call('where.exe', tool).lines.map(&:strip).reject(&:empty?)
      first = found.first
      unless first && normalize.call(first).start_with?("#{normalize.call(expected)}/")
        failures << "#{tool} resolves outside the selected MSYS2 installation: #{first.inspect}"
      end
      run.call(File.join(expected, 'usr', 'bin', "#{tool}.exe"), '--version')
    end

    # Explicit shell launch distinguishes shell PATH lookup from direct startup.
    shell = File.join(expected, 'usr', 'bin', 'sh.exe')
    run.call(shell, '-c', 'set -e; command -v make sh uname cp rm; uname -s')
    Dir.mktmpdir('msys2-utility-preflight-', ENV.fetch('RUNNER_TEMP')) do |dir|
      Dir.chdir(dir) do
        File.write('source.txt', "MSYS2 utility probe\n")
        run.call(File.join(expected, 'usr', 'bin', 'cp.exe'), 'source.txt', 'direct.txt')
        unless File.file?('direct.txt') && File.binread('direct.txt') == File.binread('source.txt')
          failures << 'Direct cp did not copy the expected bytes'
        end
        run.call(File.join(expected, 'usr', 'bin', 'rm.exe'), '-f', 'direct.txt')
        failures << 'Direct rm did not remove the copy' if File.exist?('direct.txt')

        # Use bare make, like Curses extconf, with no Curses-specific overrides.
        File.write('probe.mk', <<~MAKE)
          uname_S := $(shell uname -s)
          $(info Make shell=$(SHELL) uname=$(uname_S))
          ifeq ($(strip $(uname_S)),)
          $(error uname returned no output)
          endif
          .PHONY: copy remove
          copy:
          \tcp source.txt make.txt
          remove:
          \trm -f make.txt
        MAKE
        run.call('make', '-f', 'probe.mk', 'copy')
        unless File.file?('make.txt') && File.binread('make.txt') == File.binread('source.txt')
          failures << 'Make cp did not copy the expected bytes'
        end
        run.call('make', '-f', 'probe.mk', 'remove')
        failures << 'Make rm did not remove the copy' if File.exist?('make.txt')
      end
    end
    raise failures.join("\n") unless failures.empty?

    say.call('MSYS2 utility preflight OK')
  rescue StandardError => e
    say.call("MSYS2 utility preflight FAILED: #{e.class}: #{e.message}")
    exit 1
  end
end
