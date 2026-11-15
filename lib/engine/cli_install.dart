import 'dart:io';

import 'package:path/path.dart' as p;

import 'settings.dart';
import '../l10n.dart';

/// How each CLI is installed, with its vendor's own installer.
class CliInstaller {
  const CliInstaller._(this.kind, this.product, this.command, this.source, this.note);

  final AgentKind kind;

  /// The product's name, as its vendor writes it.
  final String product;

  /// What runs, shown to the user before asking.
  final String command;

  /// Where the installer comes from.
  final String source;

  /// What else happens, if anything.
  final String note;

  static CliInstaller of(AgentKind kind) => kind == AgentKind.codex ? codex : claude;

  static final claude = CliInstaller._(
    AgentKind.claude,
    'Claude Code',
    'irm https://claude.ai/install.ps1 | iex',
    tr('claude.ai, l\'installer ufficiale di Anthropic', 'claude.ai, Anthropic\'s official installer'),
    '',
  );

  static final codex = CliInstaller._(
    AgentKind.codex,
    'Codex CLI',
    'npm install -g @openai/codex',
    tr(
      'npm, il registro dei pacchetti dove OpenAI pubblica Codex',
      'npm, the package registry where OpenAI publishes Codex',
    ),
    tr(
      'Se Node.js manca, prima viene installato con winget (OpenJS.NodeJS.LTS).',
      'If Node.js is missing, it is installed first with winget (OpenJS.NodeJS.LTS).',
    ),
  );

  /// The PowerShell script that does it, in a window the user can read.
  String script() {
    final lines = <String>[
      r'$ErrorActionPreference = "Continue"',
      tr(
        '\$Host.UI.RawUI.WindowTitle = "Installazione di $product - AutoLoop"',
        '\$Host.UI.RawUI.WindowTitle = "Installing $product - AutoLoop"',
      ),
      tr(
        'Write-Host "Installazione di $product" -ForegroundColor Cyan',
        'Write-Host "Installing $product" -ForegroundColor Cyan',
      ),
      'Write-Host ""',
    ];
    if (kind == AgentKind.claude) {
      lines.add(command);
    } else {
      lines.addAll([
        r'$npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source',
        r'if (-not $npm) {',
        tr(
          r'  Write-Host "Node.js manca: lo installo con winget." -ForegroundColor Yellow',
          r'  Write-Host "Node.js is missing: installing it with winget." -ForegroundColor Yellow',
        ),
        r'  winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements',
        r'  $npm = Join-Path $env:ProgramFiles "nodejs\npm.cmd"',
        r'}',
        tr(
          r'if (Test-Path $npm) { & $npm install -g @openai/codex } else { Write-Host "npm non trovato: installa Node.js da nodejs.org e riprova." -ForegroundColor Red }',
          r'if (Test-Path $npm) { & $npm install -g @openai/codex } else { Write-Host "npm not found: install Node.js from nodejs.org and try again." -ForegroundColor Red }',
        ),
      ]);
    }
    lines.addAll([
      'Write-Host ""',
      tr(
        r'Write-Host "Finito. Premi Invio per tornare ad AutoLoop." -ForegroundColor Cyan',
        r'Write-Host "Done. Press Enter to go back to AutoLoop." -ForegroundColor Cyan',
      ),
      r'[void](Read-Host)',
    ]);
    return lines.join('\r\n');
  }

  /// Runs the installer in a console window of its own and returns when the
  /// user closes it.
  Future<void> run() async {
    final file = File(p.join(Directory.systemTemp.path, 'autoloop-install-${kind.name}.ps1'));
    // With a BOM, Windows PowerShell reads the script as UTF-8.
    file.writeAsStringSync('﻿${script()}');
    final quoted = file.path.replaceAll("'", "''");
    final proc = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"$quoted\"' -Wait",
    ]);
    await proc.exitCode;
  }
}
