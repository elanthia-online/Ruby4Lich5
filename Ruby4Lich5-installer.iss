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
; All three deliberately unchecked -- no silent default. NextButtonClick below blocks
; advancing past this page with the "lich" component active and none chosen,
; so an explicit choice is always required rather than assumed on the user's
; behalf (confirmed real: "lichonly" is a genuine type, Lich can install
; without Ruby at all, so this can't be gated on "full" specifically -- it's
; gated on whether the lich component is active, which covers both named
; types and a hand-picked Custom selection alike).
Name: LichGS;  Description: "Place in Desktop ({userdesktop}\Lich5 - preferred for Gemstone IV)";  GroupDescription: "Lich5 Folder Location";  Components: lich;    Flags: unchecked exclusive
Name: LichDR;  Description: "Place in Ruby4Lich5 ({app}\Lich5 - preferred for DragonRealms)";      GroupDescription: "Lich5 Folder Location";  Components: lich;    Flags: unchecked exclusive
; LichCustom shows LichDirPage (see [Code]) right after this page so the user can
; browse to any folder. LichCustomDest decides whether to add a Lich5 subfolder,
; so picking e.g. C:\Games\Lich-5 does not produce C:\Games\Lich-5\Lich5.
Name: LichCustom; Description: "Choose a different folder...";                                  GroupDescription: "Lich5 Folder Location";  Components: lich;    Flags: unchecked exclusive

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

// ---------------------------------------------------------------------------
// Custom Lich5 folder (LichCustom task)
// ---------------------------------------------------------------------------
// LichDirPage comes right after the Tasks page and is skipped unless
// LichCustom is chosen. The user picks a folder and LichCustomDest turns it
// into the folder Lich is actually copied to:
//   * If the chosen folder already looks like a Lich folder (its name is Lich5,
//     Lich-5, Lich 5, Lich_5 or Lich, in any case, or it already holds
//     lich.rbw), Lich goes straight into it. So C:\Games\Lich-5 stays
//     C:\Games\Lich-5 and does not become C:\Games\Lich-5\Lich5.
//   * Otherwise a Lich5 subfolder is added (C:\Games -> C:\Games\Lich5),
//     matching how the Desktop and Ruby4Lich5 options behave.
// NextButtonClick also catches a destination that would end up inside an
// existing Lich install (e.g. C:\Games\Lich5\scripts\Lich5) and offers that
// install's folder instead.
var
  LichDirPage: TInputDirWizardPage;
  LichDirPreview: TNewStaticText;

// Trims whitespace, turns / into \, and drops a trailing \ (drive roots keep theirs).
function NormalizeDir(const Dir: String): String;
begin
  Result := Trim(Dir);
  StringChangeEx(Result, '/', '\', True);
  if Result <> '' then
    Result := RemoveBackslashUnlessRoot(Result);
end;

// True for a drive path (C:\...) or a UNC path (\\server\share...).
// Length is checked before any indexing (nested ifs, so this is safe without
// short-circuit evaluation -- LichDirChanged calls it on every keystroke).
function IsAbsoluteDir(const Dir: String): Boolean;
begin
  Result := False;
  if Length(Dir) < 3 then
    Exit;
  if Copy(Dir, 1, 2) = '\\' then
    Result := True
  else if (Copy(Dir, 2, 2) = ':\') and
          (Pos(UpperCase(Copy(Dir, 1, 1)), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') > 0) then
    Result := True;
end;

function HasInvalidPathChars(const Dir: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(Dir) do
    if (Pos(Copy(Dir, I, 1), '*?"<>|') > 0) or ((Dir[I] = ':') and (I <> 2)) then
    begin
      Result := True;
      Exit;
    end;
end;

// Lich5, Lich-5, Lich 5, Lich_5, Lich.5, Lich (any case).
function IsLichFolderName(const Name: String): Boolean;
var
  N: String;
begin
  N := Lowercase(Name);
  StringChangeEx(N, ' ', '', True);
  StringChangeEx(N, '-', '', True);
  StringChangeEx(N, '_', '', True);
  StringChangeEx(N, '.', '', True);
  Result := (N = 'lich5') or (N = 'lich');
end;

function IsLichInstallDir(const Dir: String): Boolean;
begin
  Result := FileExists(AddBackslash(Dir) + 'lich.rbw');
end;

// The folder Lich is actually copied to for a chosen folder ('' if none chosen).
function LichCustomDest(const Chosen: String): String;
var
  Dir: String;
begin
  Dir := NormalizeDir(Chosen);
  if Dir = '' then
    Result := ''
  else if IsLichFolderName(ExtractFileName(Dir)) or IsLichInstallDir(Dir) then
    Result := Dir
  else
    Result := AddBackslash(Dir) + 'Lich5';
end;

// Nearest parent folder of Dir (not Dir itself) that already holds lich.rbw, or ''.
function FindLichAncestor(const Dir: String): String;
var
  Cur, Parent: String;
  Depth: Integer;
begin
  Result := '';
  Cur := Dir;
  Parent := ExtractFileDir(Cur);
  Depth := 0;
  while (Parent <> '') and (CompareText(Parent, Cur) <> 0) and (Depth < 64) do
  begin
    if IsLichInstallDir(Parent) then
    begin
      Result := Parent;
      Exit;
    end;
    Cur := Parent;
    Parent := ExtractFileDir(Cur);
    Depth := Depth + 1;
  end;
end;

// True when Path is Root itself or anywhere inside it (case-insensitive).
function IsSameOrInside(const Path, Root: String): Boolean;
begin
  Result := Pos(AddBackslash(Lowercase(Root)), AddBackslash(Lowercase(Path))) = 1;
end;

function IsDirEmpty(const Dir: String): Boolean;
var
  FindRec: TFindRec;
begin
  Result := True;
  if FindFirst(AddBackslash(Dir) + '*', FindRec) then
  try
    repeat
      if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
      begin
        Result := False;
        Exit;
      end;
    until not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

// Shows the resolved destination under the folder box as the user types or browses.
procedure LichDirChanged(Sender: TObject);
var
  Dir: String;
begin
  Dir := NormalizeDir(LichDirPage.Values[0]);
  if (Dir <> '') and IsAbsoluteDir(Dir) and not HasInvalidPathChars(Dir) then
    LichDirPreview.Caption := 'Lich will be installed to:' + #13#10 + ExpandFileName(LichCustomDest(Dir))
  else
    LichDirPreview.Caption := '';
end;

procedure InitializeWizard();
begin
  // AppendDir = False: Browse must not tack 'Lich5' onto whatever is picked --
  // LichCustomDest makes that call so a picked Lich5 folder is not doubled.
  LichDirPage := CreateInputDirPage(wpSelectTasks,
    'Lich5 Folder Location', 'Where should Lich be installed?',
    'Choose the folder for Lich. If the folder is not already a Lich folder ' +
    '(for example C:\Games\Lich5), Setup creates a Lich5 folder inside it.',
    False, 'Lich5');
  LichDirPage.Add('');
  LichDirPage.Values[0] := GetPreviousData('LichCustomDir', '');

  LichDirPreview := TNewStaticText.Create(LichDirPage);
  LichDirPreview.Parent := LichDirPage.Surface;
  LichDirPreview.Left := LichDirPage.Edits[0].Left;
  LichDirPreview.Top := LichDirPage.Edits[0].Top + LichDirPage.Edits[0].Height + ScaleY(16);
  LichDirPreview.Width := LichDirPage.SurfaceWidth - LichDirPreview.Left;
  LichDirPreview.WordWrap := True;
  LichDirPreview.Caption := '';

  LichDirPage.Edits[0].OnChange := @LichDirChanged;
  LichDirChanged(nil);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = LichDirPage.ID) and
            not (IsComponentSelected('lich') and WizardIsTaskSelected('LichCustom'));
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  if IsComponentSelected('lich') and WizardIsTaskSelected('LichCustom') then
    SetPreviousData(PreviousDataKey, 'LichCustomDir', NormalizeDir(LichDirPage.Values[0]));
end;

// Validates the folder on LichDirPage. Returns False to keep the user on the page.
function ValidateLichDirPage(): Boolean;
var
  Dir, Dest, Ancestor, Parent: String;
begin
  Result := False;
  Dir := NormalizeDir(LichDirPage.Values[0]);
  if Dir = '' then
  begin
    MsgBox('Please choose a folder for Lich5.', mbError, MB_OK);
    Exit;
  end;
  if not IsAbsoluteDir(Dir) or HasInvalidPathChars(Dir) then
  begin
    MsgBox('Please enter a full folder path, such as C:\Games\Lich5.', mbError, MB_OK);
    Exit;
  end;

  Dest := ExpandFileName(LichCustomDest(Dir));

  // fetch-lich.ps1 stages Lich in {app}\R4LInstall\Lich5 and xcopy copies it
  // out from there; copying into the staging folder or the Ruby tree would
  // clobber files Setup itself owns.
  if IsSameOrInside(Dest, ExpandConstant('{app}\R4LInstall')) or
     IsSameOrInside(Dest, ExpandConstant('{app}\{#RubyVersion}')) or
     IsSameOrInside(Dest, ExpandConstant('{app}\current')) then
  begin
    MsgBox('Lich cannot be installed inside Setup''s own Ruby or staging folders:' + #13#10 + Dest + #13#10#13#10 +
           'Please choose a different folder.', mbError, MB_OK);
    Exit;
  end;

  // Picked a folder inside an existing Lich install (e.g. C:\Games\Lich5\scripts).
  // Offer to use that install's folder so we never nest Lich5 inside Lich5.
  Ancestor := FindLichAncestor(Dest);
  if Ancestor <> '' then
  begin
    if MsgBox('The folder you chose is inside an existing Lich install:' + #13#10 + Ancestor + #13#10#13#10 +
              'Install Lich into ' + Ancestor + ' instead?' + #13#10 +
              '(Choose No to pick a different folder.)', mbConfirmation, MB_YESNO) = IDYES then
    begin
      LichDirPage.Values[0] := Ancestor;
      Dest := Ancestor;
    end
    else
      Exit;
  end
  else
  begin
    // No lich.rbw above it, but the parent is *named* like a Lich folder, e.g. a
    // fresh C:\Games\Lich-5 with Lich5 typed or "Make New Folder"-ed inside it.
    // Yes/No/Cancel rather than Yes/No: a Lich-named parent can be legitimate
    // (a Windows account named "Lich" -> C:\Users\Lich\Lich5).
    Parent := ExtractFileDir(Dest);
    if (Parent <> '') and (CompareText(Parent, Dest) <> 0) and
       IsLichFolderName(ExtractFileName(Parent)) then
    begin
      case MsgBox('This would put a Lich folder inside another Lich folder:' + #13#10 + Dest + #13#10#13#10 +
                  'Yes: install into ' + Parent + ' instead' + #13#10 +
                  'No: keep ' + Dest + #13#10 +
                  'Cancel: pick a different folder', mbConfirmation, MB_YESNOCANCEL) of
        IDYES:
          begin
            // Drop an empty leftover from the Browse dialog's "Make New Folder"
            // (RemoveDir only ever removes an empty directory).
            if DirExists(Dest) and IsDirEmpty(Dest) then
              RemoveDir(Dest);
            LichDirPage.Values[0] := Parent;
            Dest := Parent;
          end;
        IDNO: ;
      else
        Exit;
      end;
    end;
  end;

  // Existing, non-empty folder that is not a Lich install: Lich's files get mixed in.
  if DirExists(Dest) and not IsLichInstallDir(Dest) and not IsDirEmpty(Dest) then
  begin
    if MsgBox('This folder already exists and has other files in it:' + #13#10 + Dest + #13#10#13#10 +
              'Lich''s files will be added alongside them, replacing any with the same name. Continue?',
              mbConfirmation, MB_YESNO) <> IDYES then
      Exit;
  end;

  Result := True;
end;

// Blocks leaving the Tasks page with the "lich" component active and no
// LichGS / LichDR / LichCustom chosen -- covers "full" and "lichonly" alike (and a
// hand-picked Custom selection with lich ticked), since what actually matters
// is whether Lich is going to be installed at all, not which named type got
// selected to get there.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectTasks) and IsComponentSelected('lich') then
  begin
    if not (WizardIsTaskSelected('LichGS') or WizardIsTaskSelected('LichDR') or
            WizardIsTaskSelected('LichCustom')) then
    begin
      MsgBox('Please choose where to place your Lich5 folder before continuing.', mbError, MB_OK);
      Result := False;
    end;
  end
  else if CurPageID = LichDirPage.ID then
    Result := ValidateLichDirPage();
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

    // Place Lich where the user chose (see [Tasks] -- LichGS/LichDR/LichCustom
    // are unchecked exclusive, and NextButtonClick already guarantees exactly
    // one is selected whenever "lich" is active, so this is never a no-op).
    if WizardIsTaskSelected('LichGS') then
      XcopyDest := ExpandConstant('{userdesktop}\Lich5')
    else if WizardIsTaskSelected('LichDR') then
      XcopyDest := ExpandConstant('{app}\Lich5')
    else if WizardIsTaskSelected('LichCustom') then
      // Same resolution ValidateLichDirPage already checked on LichDirPage.
      XcopyDest := ExpandFileName(LichCustomDest(LichDirPage.Values[0]))
    else
      XcopyDest := '';

    if XcopyDest <> '' then
    begin
      CmdExe := ExpandConstant('{cmd}');

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
