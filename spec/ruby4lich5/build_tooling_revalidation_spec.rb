# frozen_string_literal: true

require 'ruby4lich5/staged_closure_revalidator'

RSpec.describe 'Recorded GTK build-only inputs' do
  def check(actual, staged: {})
    lock = double('runtime lock', closure: [], contract: { 'build_tooling' => { 'pkg-config' => { 'version' => '1.6.6' } } })
    Ruby4Lich5::StagedClosureRevalidator.new(lock: lock, staged_member_versions: staged,
                                             target_bundled_gem_versions: actual, pre_stage_baseline_versions: {}).revalidate!
  end

  it 'accounts for exact recorded build-tool versions on the build machine' do
    expect { check({ 'pkg-config' => '1.6.6' }) }.not_to raise_error
  end

  it 'rejects unexpected build-tool version drift' do
    expect { check({ 'pkg-config' => '9.9.9' }) }.to raise_error(Ruby4Lich5::StagedClosureRevalidator::RevalidationFailure, /build-only version/)
  end

  it 'continues to reject unrelated extras' do
    expect { check({ 'unreviewed' => '1.0' }) }.to raise_error(Ruby4Lich5::StagedClosureRevalidator::RevalidationFailure, /unexplained drift/)
  end

  it 'rejects build-only tools accidentally included in the staged runtime' do
    expect { check({ 'pkg-config' => '1.6.6' }, staged: { 'pkg-config' => '1.6.6' }) }.to raise_error(Ruby4Lich5::StagedClosureRevalidator::RevalidationFailure, /staged but not present/)
  end
end
