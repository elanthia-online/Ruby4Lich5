# frozen_string_literal: true

require 'yaml'
require 'ruby4lich5/target_platform'

# Every platform-dependent workflow value R3 parameterized, evaluated for one
# platform row: job ids, display names, runner labels, concurrency groups,
# MSYS2 settings, job env, platform env on steps, artifact names, and the
# RubyInstaller asset and release-download names the run scripts build. The committed golden
# (spec/fixtures/platform-table/x64-workflow-snapshot.json) was produced by
# running this module against the pre-R3 workflows, which contain no
# platform expressions at all, so the spec comparing it with the current
# tree proves the x64 values are unchanged rather than restating the table.
#
# Only the plumbing R3 introduces is evaluated: +inputs.platform+,
# +needs.<job>.outputs.<key>+ and +steps.<id>.outputs.<key>+ that trace back
# to the select-target-platform action, +env.R4L5_*+ in +with:+, and
# +$env:R4L5_*+ in run scripts. Anything else is left verbatim.
module X64WorkflowSnapshot
  WORKFLOWS = %w[
    ruby4-bundled-gems-suite.yml promote-gem-candidate.yml build-ruby4lich5-installer.yaml
    msys2-package-list-diagnostic.yml rubyinstaller-provenance.yml validate-novel-gem.yml
  ].freeze
  ACTION = './.github/actions/select-target-platform'
  LEADER = 'select_platform'
  TOKENS = [%r{rubyinstaller-[^"'\s)]+}, /ruby4-bundled-gems-windows-[a-z0-9]+/, %r{releases/download/[^/"'\s]+/}].freeze
  EXPRESSION = /\$\{\{\s*([^}]+?)\s*\}\}/

  # The action's output names, as row values. A Pester test checks the
  # action itself emits exactly these.
  def self.action_outputs(row)
    {
      'platform' => row.name, 'runner' => row.runner, 'msystem' => row.msystem,
      'msys2-prefix' => row.msys2_prefix, 'msys2-package-prefix' => row.msys2_package_prefix,
      'rubyinstaller-asset-suffix' => row.rubyinstaller_asset_suffix, 'gem-bundle-tag' => row.gem_bundle_tag,
      'toolchain-cc' => row.toolchain.fetch('cc'), 'toolchain-make' => row.toolchain.fetch('make'),
      'toolchain-pkg-config' => row.toolchain.fetch('pkg_config'), 'toolchain-objdump' => row.toolchain.fetch('objdump')
    }
  end

  # +table+ defaults to this checkout's own table; the golden was captured
  # from a pre-R3 tree, which has no table and no expressions to evaluate.
  def self.capture(root, platform: 'x64-mingw-ucrt', table: Ruby4Lich5::TargetPlatform::TABLE)
    row = Ruby4Lich5::TargetPlatform.select(platform, table: table)
    WORKFLOWS.to_h { |name| [name, workflow(YAML.load_file(File.join(root, '.github', 'workflows', name)), row)] }
  end

  def self.workflow(data, row)
    jobs = data.fetch('jobs')
    outputs = job_outputs(jobs, row)
    eval = ->(value) { evaluate(value, row, outputs) }
    {
      'concurrency' => data['concurrency']&.transform_values(&eval),
      'jobs'        => jobs.except(LEADER).to_h { |id, job| [id, job_snapshot(job, eval)] }
    }
  end

  def self.job_snapshot(job, eval)
    env = (job['env'] || {}).transform_values(&eval)
    steps = (job['steps'] || []).reject { |step| step['uses'] == ACTION }
    {
      'name'        => eval.call(job['name']),
      'runs-on'     => eval.call(job['runs-on']),
      'needs'       => Array(job['needs']) - [LEADER],
      'if'          => job['if'],
      'concurrency' => job['concurrency']&.transform_values(&eval),
      'env'         => env.reject { |key, _| key.start_with?('R4L5_') },
      'steps'       => steps.filter_map { |step| step_snapshot(step, env, eval) }
    }.compact
  end

  # Only a step's platform-dependent values; nil when it has none.
  def self.step_snapshot(step, job_env, eval)
    step_env = (step['env'] || {}).transform_values(&eval)
    env = job_env.merge(step_env)
    with = (step['with'] || {}).slice('msystem', 'name').transform_values do |value|
      eval.call(value).then { |text| text.is_a?(String) ? text.gsub(/\$\{\{\s*env\.(R4L5_\w+)\s*\}\}/) { env.fetch(Regexp.last_match(1)) } : text }
    end
    with = {} unless step['uses'].to_s.match?(%r{\A(?:actions/(?:upload|download)-artifact|msys2/setup-msys2)@})
    run = step['run'].to_s.gsub(/\$env:(R4L5_\w+)/) { env.fetch(Regexp.last_match(1)) }
    values = {
      'env'        => step_env.slice('GEM_PLATFORM', 'MSYSTEM', 'MSYS2_PREFIX', 'MSYS2_PACKAGE_PREFIX'),
      'with'       => with,
      'run_tokens' => TOKENS.flat_map { |pattern| run.scan(pattern) }
    }.reject { |_, value| value.empty? }
    { 'name' => step['name'] || step['uses'] }.merge(values) unless values.empty?
  end

  # Row-derived outputs only: the leader's or a step's select-target-platform
  # outputs, and relays of those through needs. Build-step outputs stay as-is.
  def self.job_outputs(jobs, row)
    values = action_outputs(row)
    resolved = {}
    2.times do
      jobs.each do |id, job|
        action_ids = (job['steps'] || []).select { |step| step['uses'] == ACTION }.map { |step| step.fetch('id') }
        (job['outputs'] || {}).each do |key, value|
          match = value.match(/\A\$\{\{\s*(?:steps\.([\w-]+)|needs\.(\w+))\.outputs\.([\w-]+)\s*\}\}\z/)
          next unless match

          step, need, field = match.captures
          if step && action_ids.include?(step)
            (resolved[id] ||= {})[key] = values.fetch(field)
          elsif need && resolved.dig(need, field)
            (resolved[id] ||= {})[key] = resolved.dig(need, field)
          end
        end
      end
    end
    resolved
  end

  def self.evaluate(value, row, outputs)
    return value unless value.is_a?(String)

    value.gsub(EXPRESSION) do |whole|
      case Regexp.last_match(1)
      when 'inputs.platform' then row.name
      when /\Aneeds\.(\w+)\.outputs\.([\w-]+)\z/ then outputs.dig(Regexp.last_match(1), Regexp.last_match(2)) || whole
      else whole
      end
    end
  end
end
