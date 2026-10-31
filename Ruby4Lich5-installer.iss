; Ruby4Lich5 -- baked installer (non-DevKit, binary-gem factory model)
;
; The Ruby tree is built on the CI runner: stock RubyInstaller (.7z) extracted,
; then the precompiled binary gems are `gem install --local`'d straight into it.
; No MSYS2, no compilation, no prune -- the binary gems are self-contained
; (they vendor their own DLLs). This installer just lays that finished tree down:
; one app, file-copy fast, responsive. DevKit stays optional via ridk.
;
; Lich itself is fetched at INSTALL time, not baked in at CI build time --
; fetch-lich.ps1 (bundled via [Files] Flags: dontcopy) pulls
; elanthia-online/lich-5's latest Release, always -- no tag-override plumbing
; (dropped 2026-07-08 for this iteration; a specific non-latest Lich is
; available directly from the EO/lich-5 release page today) -- matching what
; its own release-on-push-stable.yaml already does at build time for the
; legacy R4LGTK3.iss (same lich-5.zip
; asset, same resulting Lich5/ folder shape -- verified directly against both
; the real asset and that real, currently-working workflow before writing
; this). See docs/PUNCHLIST-remaining-work.md's Item 6 sections for why: Lich
; can gain a gem requirement without a human pushing it through Ruby4Lich5's
; front door first ("one team, two repos"), so "always latest" is safe for
; Lich specifically in a way it explicitly is not for Ruby+Gems, which stay
; baked.
;
; Build-time injected defines (workflow passes via ISCC /D...):
;   RubyVersion       e.g. 4.0.5 (resolved "latest 4.0.x")
;   GemBundleVersion   identity of the verified gem artifact actually baked in
;   InstallerVersion   Ruby4Lich5's own installer-build identity -- independent of both
;                      of the above; installer versioning is owned by Ruby4Lich5, not by
;                      lich-5 (docs/DECISIONS.md Phase 1, item 4)
;
; LichVersion is deliberately NOT a build-time define anymore -- it's only
; known once fetch-lich.ps1 actually resolves a real tag at install time, so
; showing one in a static, compile-time AppVerName could be flat wrong the
; moment "latest" moves past whatever was true when this installer was built.

#ifndef RubyVersion
  #error "RubyVersion must be supplied from the verified target configuration"
#endif
#ifndef GemBundleVersion
  #define GemBundleVersion "0.0.0-dev"
#endif
#ifndef InstallerVersion
  #define InstallerVersion "0.0.0"
#endif

#define MyAppName "Ruby4Lich5"
#define MyAppPublisher "Elanthia-Online"
#define MyAppURL "https://github.com/elanthia-online/lich-5/"

[Setup]
; AppId identifies the Lich 5 application; do NOT change it (new GUID only at Lich 6).
AppId={{edd9ccd7-33cb-4577-a470-fe8fd087eb07}
AppName={#MyAppName}
AppVersion={#InstallerVersion}
AppVerName={#MyAppName} Ruby {#RubyVersion} (Gems {#GemBundleVersion}) -- Lich fetched at install
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
SetupLogging=yes
ChangesAssociations=yes
ChangesEnvironment=true
DefaultDirName=C:\Ruby4Lich5
DisableStartupPrompt=Yes
DisableProgramGroupPage=Yes
DisableWelcomePage=Yes
DisableReadyPage=Yes
UsePreviousAppDir=No
PrivilegesRequired=lowest
OutputBaseFilename=Ruby4Lich5
SetupIconFile=.\fly64.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Types]
Name: "full";      Description: "Both Lich and Ruby"
Name: "lichonly";  Description: "Lich Installation Only"
Name: "rubyonly";  Description: "Ruby Installation Only"

[Components]
Name: "lich";     Description: "Lich Files";                             Types: full lichonly
Name: "rubygem";  Description: "Ruby {#RubyVersion} (64-bit) with Gems"; Types: full rubyonly

[Tasks]
; Both deliberately unchecked -- no silent default. NextButtonClick below blocks
; advancing past this page with the "lich" component active and neither chosen,
; so an explicit choice is always required rather than assumed on the user's
; behalf (confirmed real: "lichonly" is a genuine type, Lich can install
; without Ruby at all, so this can't be gated on "full" specifically -- it's
; gated on whether the lich component is active, which covers both named
; types and a hand-picked Custom selection alike).
Name: LichGS;  Description: "Place in Desktop ({userdesktop}\Lich5 - preferred for Gemstone IV)";  GroupDescription: "Lich5 Folder Location";  Components: lich;    Flags: unchecked exclusive
Name: LichDR;  Description: "Place in Ruby4Lich5 ({app}\Lich5 - preferred for DragonRealms)";      GroupDescription: "Lich5 Folder Location";  Components: lich;    Flags: unchecked exclusive

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Dirs]
Name: "{app}\R4LInstall"; Attribs: hidden

[Files]
; The pre-baked Ruby tree: RubyInstaller + binary gems already installed in, staged by CI at .\ruby.
Source: ".\ruby\*";    DestDir: "{app}\{#RubyVersion}"; Components: rubygem; Flags: ignoreversion createallsubdirs recursesubdirs
Source: ".\fly64.ico"; DestDir: "{app}\R4LInstall";     Components: lich;    Flags: ignoreversion
; Lich itself is NOT staged here anymore -- fetch-lich.ps1 populates
; {app}\R4LInstall\Lich5 at install time instead (see [Code]). Bundled as a
; helper script only, extracted to {tmp} for the duration of Setup, never
; part of the installed tree.
Source: ".\fetch-lich.ps1"; DestDir: "{tmp}"; Components: lich; Flags: dontcopy
Source: ".\update-ruby-path.ps1"; DestDir: "{app}\R4LInstall"; Components: rubygem; Flags: ignoreversion

[Registry]
; We lay down a tree (no RubyInstaller run), so we set associations + PATH ourselves.
; Restored verbatim from the legacy R4LGTK3.iss -- proven for months.
Root: HKCU; Subkey: "SOFTWARE\Classes\.rb";                          ValueType: string; ValueName: ""; ValueData: "RubyFile";                                         Components: rubygem; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKCU; Subkey: "SOFTWARE\Classes\.rbw";                         ValueType: string; ValueName: ""; ValueData: "RubyWFile";                                        Components: rubygem; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyFile";                     ValueType: string; ValueName: ""; ValueData: "RubyFile";                                         Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyWFile";                    ValueType: string; ValueName: ""; ValueData: "RubyWFile";                                        Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyFile\DefaultIcon";         ValueType: string; ValueName: ""; ValueData: "{app}\{#RubyVersion}\bin\ruby.exe,0";              Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyWFile\DefaultIcon";        ValueType: string; ValueName: ""; ValueData: "{app}\{#RubyVersion}\bin\rubyw.exe,0";             Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyFile\shell\open\command";  ValueType: string; ValueName: ""; ValueData: """{app}\{#RubyVersion}\bin\ruby.exe"" ""%1"" %*";  Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyWFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#RubyVersion}\bin\rubyw.exe"" ""%1"" %*"; Components: rubygem; Flags: uninsdeletekey
; User PATH is normalized by update-ruby-path.ps1 after Ruby is installed.

[Run]
; Optional DevKit for developers -- ridk ships in the baked tree; pulls ~1.5GB of
; MSYS2 over the network. Offered as a finish-page checkbox (postinstall), not a
; Tasks-page one: running this hidden mid-wizard (the old waituntilterminated
; runhidden combination) blocked the wizard's UI thread for the whole download,
; making Setup look hung. nowait + a visible console instead matches
; RubyInstaller's own reference .iss for this exact step.
Filename: "{app}\{#RubyVersion}\bin\ridk.cmd"; Parameters: "install 2 3"; \
  Description: "Install Ruby DevKit (developers -- downloads MSYS2, needs network)"; \
  Components: rubygem; Flags: postinstall nowait skipifsilent unchecked

[Code]
// Refuses /SILENT and /VERYSILENT outright rather than special-casing around
// them -- Doug's explicit call: Ruby4Lich5.exe is not meant to support
// unattended installs at all, not just "don't let silent installs abort on
// the Lich placement guard below." Fires in InitializeSetup specifically
// (confirmed via jrsoftware's own docs and canonical example for this exact
// check): it runs before the wizard form exists, so Result := False aborts
// Setup immediately -- NextButtonClick's simulated-click behavior in silent
// mode never gets a chance to run at all. MsgBox (not SuppressibleMsgBox) is
// deliberate: only an explicit /SUPPRESSMSGBOXES hides it, so the refusal
// stays visible unless a caller goes out of their way to silence it too --
// and Log() still records the refusal either way (SetupLogging=yes above).
function InitializeSetup(): Boolean;
begin
  Result := True;
  if WizardSilent then
  begin
    Log('Silent install refused: Ruby4Lich5 does not support unattended installation.');
    MsgBox('Ruby4Lich5 does not support silent installation. ' +
           'Please run Setup interactively.', mbCriticalError, MB_OK);
    Result := False;
  end;
end;

// Blocks leaving the Tasks page with the "lich" component active and neither
// LichGS nor LichDR chosen -- covers "full" and "lichonly" alike (and a
// hand-picked Custom selection with lich ticked), since what actually matters
// is whether Lich is going to be installed at all, not which named type got
// selected to get there.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectTasks) and IsComponentSelected('lich') then
  begin
    if not (WizardIsTaskSelected('LichGS') or WizardIsTaskSelected('LichDR')) then
    begin
      MsgBox('Please choose where to place your Lich5 folder (Gemstone IV or DragonRealms) before continuing.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

// Normalize only this install root's Ruby entries in the current user's PATH.
// PATH-only failures return to the caller so selected Lich work can continue.
procedure UpdateRubyPath(Mode: String);
var
  ScriptPath, Params: String;
  ResultCode: Integer;
begin
  ScriptPath := ExpandConstant('{app}\R4LInstall\update-ruby-path.ps1');
  if not FileExists(ScriptPath) then
  begin
    if Mode = 'Install' then
    begin
      Log('Ruby is installed, but the PATH helper is missing.');
      MsgBox('Ruby is installed, but its PATH helper is missing. ' +
        'Re-run Setup to repair it, or add ' + ExpandConstant('{app}\{#RubyVersion}\bin') +
        ' to your user PATH before starting Lich.', mbCriticalError, MB_OK);
      Exit;
    end;
    Log('No Ruby PATH helper installed; leaving user PATH unchanged.');
    Exit;
  end;
  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath +
    '" -Mode ' + Mode + ' -InstallRoot "' + ExpandConstant('{app}') +
    '" -RubyVersion "{#RubyVersion}"';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
  begin
    if Mode = 'Uninstall' then
    begin
      Log('Could not clean up Ruby entries in user PATH; continuing uninstall. ' +
        'Remove stale entries for ' + ExpandConstant('{app}') + ' manually if needed.');
      Exit;
    end;
    Log('Ruby is installed, but updating its user PATH failed.');
    MsgBox('Ruby is installed, but its user PATH could not be updated. ' +
      'See the Setup log, then re-run Setup or add ' + ExpandConstant('{app}\{#RubyVersion}\bin') +
      ' to your user PATH before starting Lich.', mbCriticalError, MB_OK);
    Exit;
  end;
end;

// Fetches Lich (see fetch-lich.ps1's own header for the full design), then
// places it at the user's chosen location, once the main file-copy step
// finishes. Both steps live here in Code rather than the fetch in Code plus
// the copy as a [Run] entry, as originally built -- confirmed against
// jrsoftware/issrc's TMainForm.Install: ProcessRunEntries (which runs [Run])
// executes, and only afterward does SetStep(ssPostInstall) fire
// CurStepChanged. A [Run]-section xcopy would
// therefore always run BEFORE this fetch, against an empty/nonexistent
// source -- Lich would never reach the user's folder. Doing both steps here,
// in order, is the only way to guarantee the copy sees real content.
// Ruby junction and PATH work runs first, independent of optional Lich.
// A Lich acquisition or placement failure leaves that completed Ruby work intact.
// Always fetches latest -- no tag-override plumbing (2026-07-08: dropped for
// this iteration, see fetch-lich.ps1's own header for why).
procedure CurStepChanged(CurStep: TSetupStep);
var
  ScriptPath, DestDir, CmdExe, XcopyDest, Params, LinkPath, RubyDir: String;
  ResultCode: Integer;
begin
  // Point a stable {app}\current at the versioned Ruby tree we just laid down,
  // so front-ends can hardcode {app}\current\bin instead of a path that moves
  // every time the baked Ruby version changes. Uses a directory JUNCTION
  // (mklink /J), not a symbolic link (mklink /D), on purpose: junctions need
  // no elevation, and this installer is PrivilegesRequired=lowest -- a /D link
  // would fail for a standard user unless Developer Mode happened to be on.
  // Both ends are local, same-volume, absolute paths -- exactly what a
  // junction handles; front-ends see current\bin\ruby.exe transparently.
  // Separate rubygem-gated block (independent of the Lich block below) so it
  // runs for a "rubyonly" install too. Non-fatal by design: Ruby is already
  // fully installed and usable at the versioned path, so a junction hiccup
  // (AV interference, a pre-existing non-empty 'current') must not abort an
  // otherwise-good install.
  if (CurStep = ssPostInstall) and IsComponentSelected('rubygem') then
  begin
    CmdExe := ExpandConstant('{cmd}');
    LinkPath := ExpandConstant('{app}\current');
    RubyDir := ExpandConstant('{app}\{#RubyVersion}');

    // Clear any prior 'current' first so a version bump re-points cleanly --
    // mklink refuses to create over an existing name. Plain rmdir (no /s)
    // removes only a junction's reparse point, never the target's files, and
    // fails safe on a real non-empty directory rather than deleting it.
    // Result ignored: we only care whether the mklink below succeeds.
    Exec(CmdExe, '/c rmdir "' + LinkPath + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

    Params := '/c mklink /J "' + LinkPath + '" "' + RubyDir + '"';
    if not Exec(CmdExe, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      Log('Could not create ' + LinkPath + ' junction -> ' + RubyDir + ' (non-fatal; versioned path still works).');
    UpdateRubyPath('Install');
  end;

  if (CurStep = ssPostInstall) and IsComponentSelected('lich') then
  begin
    // Custom status text, since the fetch is a blocking Exec below with its
    // own console now hidden (SW_HIDE -- it was SW_SHOW; nothing about this
    // call needed a visible window, that was just carried over from a
    // different, non-blocking [Run] step without re-examining it for this
    // spot). Repaint, not just setting Caption, is required here: Exec blocks
    // the UI thread, so the normal Windows message pump that would otherwise
    // paint the new text never runs before the wait begins -- Repaint forces
    // the label to draw immediately instead of waiting for that pump.
    WizardForm.StatusLabel.Caption := 'Fetching latest Lich...';
    WizardForm.StatusLabel.Repaint;

    ExtractTemporaryFile('fetch-lich.ps1');
    ScriptPath := ExpandConstant('{tmp}\fetch-lich.ps1');
    DestDir := ExpandConstant('{app}\R4LInstall\Lich5');

    Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '" -DestDir "' + DestDir + '"';

    if not Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    begin
      MsgBox('Failed to download Lich (network unreachable, or GitHub could not be reached). ' +
             'Setup cannot continue with the Lich component selected. ' +
             'You can re-run Setup once connected, or install Ruby/Gems only for now.',
             mbCriticalError, MB_OK);
      Abort;
    end;

    // Place Lich where the user chose (see [Tasks] -- LichGS/LichDR are
    // unchecked exclusive, and NextButtonClick already guarantees exactly one
    // is selected whenever "lich" is active, so this is never a no-op).
    if WizardIsTaskSelected('LichGS') or WizardIsTaskSelected('LichDR') then
    begin
      CmdExe := ExpandConstant('{cmd}');
      if WizardIsTaskSelected('LichGS') then
        XcopyDest := ExpandConstant('{userdesktop}\Lich5')
      else
        XcopyDest := ExpandConstant('{app}\Lich5');

      Params := '/c xcopy /i /e /s /y "' + DestDir + '" "' + XcopyDest + '"';
      if not Exec(CmdExe, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      begin
        MsgBox('Lich was downloaded but could not be placed at ' + XcopyDest + '.', mbCriticalError, MB_OK);
        Abort;
      end;
    end;
  end;
end;

// Remove the {app}\current junction on uninstall. Plain rmdir (no /s) deletes
// only the reparse point, never the target's contents, and is a harmless
// no-op if 'current' was never created (e.g. a Lich-only install).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  CmdExe, LinkPath: String;
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    UpdateRubyPath('Uninstall');
    CmdExe := ExpandConstant('{cmd}');
    LinkPath := ExpandConstant('{app}\current');
    Exec(CmdExe, '/c rmdir "' + LinkPath + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
