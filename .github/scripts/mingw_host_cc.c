/*
 * Compiler wrapper for the aarch64-mingw-ucrt sqlite3 build only
 * (ruby4-bundled-gems-suite.yml, "Build and stage runtime gem bundle").
 *
 * sqlite3 builds its packaged SQLite through mini_portile2, which takes the
 * configure --host from "$CC -v"'s "Target:" line. MSYS2's clangarm64 clang
 * reports aarch64-w64-windows-gnu, which SQLite's config.sub rejects
 * ("Kernel 'windows' not known to work with OS 'gnu'"). The same triple
 * normalization as mrhoribu/sqlite3-ruby PR #2,
 * host.sub(/-w64-windows-gnu\z/, "-w64-mingw32"), is applied here without
 * patching the gem: for a bare "-v" this prints the real compiler's output
 * with only that suffix of the Target line rewritten. Every other
 * invocation runs the real compiler (MINGW_HOST_CC_REAL) with this process's
 * command line unchanged and returns its exit code.
 *
 * Remove it, and pass sqlite3 through, once sqlite3-ruby publishes an
 * aarch64-mingw-ucrt platform gem.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <windows.h>

static const char SUFFIX[] = "-w64-windows-gnu";
static const char REPLACEMENT[] = "-w64-mingw32";

/* The part of this process's command line after its own program name. */
static const wchar_t *arguments(const wchar_t *line) {
  if (*line == L'"') {
    line++;
    while (*line && *line != L'"') line++;
    if (*line) line++;
  } else {
    while (*line && *line != L' ' && *line != L'\t') line++;
  }
  return line;
}

static int version(const char *real) {
  char command[MAX_PATH * 2];
  snprintf(command, sizeof command, "\"\"%s\" -v 2>&1\"", real);
  FILE *output = _popen(command, "r");
  if (!output) return 1;
  char line[4096];
  while (fgets(line, sizeof line, output)) {
    char *end = line + strcspn(line, "\r\n");
    size_t length = (size_t)(end - line), suffix = sizeof SUFFIX - 1;
    if (strncmp(line, "Target: ", 8) == 0 && length >= suffix && strncmp(end - suffix, SUFFIX, suffix) == 0) {
      fprintf(stderr, "%.*s%s%s", (int)(length - suffix), line, REPLACEMENT, end);
    } else {
      fputs(line, stderr);
    }
  }
  return _pclose(output);
}

int main(int argc, char **argv) {
  const char *real = getenv("MINGW_HOST_CC_REAL");
  const wchar_t *wide_real = _wgetenv(L"MINGW_HOST_CC_REAL");
  if (!real || !wide_real) {
    fputs("mingw_host_cc: MINGW_HOST_CC_REAL is not set\n", stderr);
    return 2;
  }
  if (argc == 2 && strcmp(argv[1], "-v") == 0) return version(real);

  const wchar_t *rest = arguments(GetCommandLineW());
  size_t size = wcslen(wide_real) + wcslen(rest) + 3;
  wchar_t *line = malloc(size * sizeof *line);
  if (!line) return 1;
  swprintf(line, size, L"\"%ls\"%ls", wide_real, rest);
  STARTUPINFOW startup;
  ZeroMemory(&startup, sizeof startup);
  startup.cb = sizeof startup;
  PROCESS_INFORMATION process;
  if (!CreateProcessW(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) {
    fprintf(stderr, "mingw_host_cc: cannot run %s (error %lu)\n", real, GetLastError());
    return 1;
  }
  WaitForSingleObject(process.hProcess, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(process.hProcess, &code);
  CloseHandle(process.hProcess);
  CloseHandle(process.hThread);
  return (int)code;
}
