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
    expect(path_update).to be < post_install.index("WizardIsComponentSelected('lich')")
    expect(path_update).to be < post_install.index("ExtractTemporaryFile('fetch-lich.ps1')")
    expect(path_update).to be < post_install.index('{sys}\xcopy.exe')
  end

  it 'returns before the install error path when uninstall cleanup cannot execute or exits nonzero' do
    failure = path_helper.split('if not Exec', 2).last
    expect(failure).to include('or (ResultCode <> 0) then')
    branch = failure.match(/if Mode = 'Uninstall' then\s+begin(.*?)end;/m)[1]
    expect(branch).to include('Log(', 'continuing uninstall', 'Exit;')
    expect(branch).not_to include('Abort', 'MsgBox')
    expect(failure.index('Exit;')).to be < failure.index("Log('Ruby is installed")
  end

  it 'returns from a missing install helper after warning without aborting the post-install event' do
    missing = path_helper.split('Params :=', 2).first
    branch = missing.match(/if Mode = 'Install' then\s+begin(.*?)end;/m)[1]
    expect(branch).to include('Log(', 'MsgBox(', 'Re-run Setup', 'Exit;')
    expect(branch).not_to include('Abort;')
  end

  it 'returns after launch failure or nonzero exit while retaining the install repair warning' do
    failure = path_helper.split('if not Exec', 2).last
    expect(failure).to include('or (ResultCode <> 0) then')
    install_failure = failure.split("Log('Ruby is installed, but updating its user PATH failed.');", 2).last
    expect(install_failure).to include('MsgBox(', 're-run Setup', 'Exit;')
    expect(install_failure).not_to include('Abort;')
    expect(path_helper).not_to include('Abort;')
  end

  { 'full' => %w[lich rubygem], 'rubyonly' => ['rubygem'], 'lichonly' => ['lich'] }.each do |mode, expected|
    it "keeps component-gated PATH and Lich work independent for #{mode}" do
      components = source.split('[Components]', 2).last.split('[Tasks]', 2).first
      selected = components.lines.filter_map do |line|
        entry = line.match(/Name: "([^"]+)";.*Types:\s*(.*)/)
        entry[1] if entry && entry[2].split.include?(mode)
      end
      expect(selected.sort).to eq(expected.sort)
      expect(post_install).to include("if (CurStep = ssPostInstall) and WizardIsComponentSelected('rubygem') then",
                                      "if (CurStep = ssPostInstall) and WizardIsComponentSelected('lich') then")
      expect(post_install.index("UpdateRubyPath('Install')")).to be < post_install.index("WizardIsComponentSelected('lich')")
      expect(path_helper).not_to include('Abort;')
    end
  end

  describe 'Lich failures after the files are installed' do
    let(:lich_block) { post_install.split("WizardIsComponentSelected('lich') then", 2).last }
    let(:fetch_failure) { lich_block.split('if not FetchOK then', 2).last.split('if XcopyDest', 2).first }
    let(:copy_failure) { lich_block.split('{sys}\xcopy.exe', 2).last }
    let(:finished_page) { source.split('procedure CurPageChanged', 2).last.split(/^end;/, 2).first }
    let(:exit_code) { source.split('function GetCustomSetupExitCode', 2).last.split(/^end;/, 2).first }

    # A modal box at ssPostInstall blocks until clicked (a UI-automated run
    # hung on one until its timeout), and Abort cannot stop the wizard there.
    it 'records the failure instead of showing a message box or aborting' do
      [fetch_failure, copy_failure].each do |branch|
        expect(branch).to include('RecordLichFailure(', 'Exit;')
        expect(branch).not_to include('MsgBox', 'Abort')
      end
      expect(post_install.split("WizardIsComponentSelected('lich') then", 2).last).not_to include('MsgBox', 'Abort;')
    end

    it 'tells the user what failed, that it is usually rate limiting, and how to install Lich by hand' do
      expect(fetch_failure).to include('LichFetchFailure', 'Wait a few minutes, then run Setup again',
                                       'https://github.com/elanthia-online/lich-5/releases/latest', 'XcopyDest')
      expect(copy_failure).to include('XcopyDest', 'DestDir')
    end

    it 'resolves the destination before the fetch so the failure text can name it' do
      expect(lich_block.index('XcopyDest := ExpandConstant')).to be < lich_block.index("ExtractTemporaryFile('fetch-lich.ps1')")
    end

    it "keeps the helper's own FAILURE reason for the finished page" do
      callback = source.split('procedure LichFetchOutput', 2).last.split(/^end;/, 2).first
      expect(callback).to include("Copy(S, 1, 9) = 'FAILURE: '", 'LichFetchFailure := Copy(S, 10')
      expect(lich_block.index("LichFetchFailure := '';")).to be < lich_block.index('ExecAndLogOutput(')
    end

    it 'rewrites the finished page and returns a nonzero exit code when Lich was not installed' do
      expect(finished_page).to include('wpFinished', "LichFailureMessage <> ''", 'FinishedHeadingLabel.Caption',
                                       'FinishedLabel.Caption := LichFailureMessage')
      expect(exit_code).to include('Result := 0;', "if LichFailureMessage <> '' then", 'Result := 100;')
    end
  end

  it 'describes completed Ruby installation and gives a concrete PATH repair path' do
    expect(path_helper).not_to include('Setup cannot finish Ruby installation')
    expect(path_helper).to include('Ruby is installed, but its PATH helper is missing.',
                                   'Ruby is installed, but its user PATH could not be updated.',
                                   "ExpandConstant('{app}\\{#RubyVersion}\\bin')")
  end
end
