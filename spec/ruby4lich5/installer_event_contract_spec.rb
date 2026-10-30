# frozen_string_literal: true

RSpec.describe 'Installer event safety contracts' do
  let(:source) { File.read(File.expand_path('../../Ruby4Lich5-installer.iss', __dir__)) }
  let(:post_install) { source.split('procedure CurStepChanged', 2).last.split('procedure CurUninstallStepChanged', 2).first }
  let(:path_helper) { source.split('procedure UpdateRubyPath', 2).last.split('procedure CurStepChanged', 2).first }

  # These guard event ordering and exception boundaries in the shipped Pascal
  # source. Native Inno execution remains a Windows acceptance check.
  it 'completes Ruby junction and PATH work before either fallible Lich operation' do
    path_update = post_install.index("UpdateRubyPath('Install')")
    expect(post_install.index('mklink /J')).to be < path_update
    expect(path_update).to be < post_install.index("IsComponentSelected('lich')")
    expect(path_update).to be < post_install.index("ExtractTemporaryFile('fetch-lich.ps1')")
    expect(path_update).to be < post_install.index('/c xcopy')
  end

  it 'returns before the install error path when uninstall cleanup cannot execute or exits nonzero' do
    failure = path_helper.split('if not Exec', 2).last
    expect(failure).to include('or (ResultCode <> 0) then')
    branch = failure.match(/if Mode = 'Uninstall' then\s+begin(.*?)end;/m)[1]
    expect(branch).to include('Log(', 'continuing uninstall', 'Exit;')
    expect(branch).not_to include('Abort', 'MsgBox')
    expect(failure.index('Exit;')).to be < failure.index('Abort;')
  end

  it 'describes completed Ruby installation and gives a concrete PATH repair path' do
    expect(path_helper).not_to include('Setup cannot finish Ruby installation')
    expect(path_helper).to include('Ruby is installed, but its PATH helper is missing.',
                                   'Ruby is installed, but its user PATH could not be updated.',
                                   "ExpandConstant('{app}\\{#RubyVersion}\\bin')")
  end
end
