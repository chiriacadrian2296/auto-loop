import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum KillReason { idleTimeout, timeout, stopped }

class ProcessOutcome {
  ProcessOutcome(this.exitCode, this.killReason);
  final int exitCode;
  final KillReason? killReason;
}

/// A cancellable child process with total and inactivity timeouts.
///
/// On Windows the whole process tree is killed (`taskkill /T`), because CLIs
/// started through `.cmd` shims or node wrappers spawn grandchildren that
/// would otherwise keep running after the parent dies.
class ManagedProcess {
  ManagedProcess._(this._process);

  final Process _process;
  KillReason? _killReason;
  bool _killed = false;

  int get pid => _process.pid;

  static Future<(ManagedProcess, Future<ProcessOutcome>)> start({
    required String executable,
    required List<String> args,
    required String workingDirectory,
    String? stdin,
    required Duration timeout,
    Duration? idleTimeout,
    required void Function(String line, bool stderr) onLine,
    IOSink? rawLog,
    Map<String, String> environment = const {},
  }) async {
    final ext = executable.toLowerCase();
    final shell = ext.endsWith('.cmd') || ext.endsWith('.bat');
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      runInShell: shell,
      environment: {'NO_COLOR': '1', 'FORCE_COLOR': '0', 'GIT_TERMINAL_PROMPT': '0', ...environment},
    );
    final managed = ManagedProcess._(process);
    return (managed, managed._supervise(stdin, timeout, idleTimeout, onLine, rawLog));
  }

  Future<ProcessOutcome> _supervise(
    String? input,
    Duration timeout,
    Duration? idleTimeout,
    void Function(String, bool) onLine,
    IOSink? rawLog,
  ) async {
    final started = DateTime.now();
    var lastOutput = started;

    // Completion is captured at subscription time: a stream that closes before
    // the exit code arrives must not leave us waiting for a done event.
    (StreamSubscription<String>, Future<void>) listen(Stream<List<int>> s, bool stderr) {
      final done = Completer<void>();
      final sub = s
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            (line) {
              lastOutput = DateTime.now();
              rawLog?.writeln(stderr ? '[stderr] $line' : line);
              onLine(line, stderr);
            },
            onDone: done.complete,
            onError: (_) {},
            cancelOnError: false,
          );
      return (sub, done.future);
    }

    final (out, outDone) = listen(_process.stdout, false);
    final (err, errDone) = listen(_process.stderr, true);

    try {
      if (input != null) _process.stdin.add(utf8.encode(input));
      await _process.stdin.flush();
      await _process.stdin.close();
    } catch (_) {
      // The process may exit before reading stdin; its exit code tells the story.
    }

    final watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      if (now.difference(started) >= timeout) {
        kill(KillReason.timeout);
      } else if (idleTimeout != null && now.difference(lastOutput) >= idleTimeout) {
        kill(KillReason.idleTimeout);
      }
    });

    final code = await _process.exitCode;
    watchdog.cancel();
    // Let buffered lines drain, but never hang on a pipe kept open by an orphan.
    await Future.wait([outDone, errDone])
        .timeout(const Duration(seconds: 5), onTimeout: () => const []);
    await out.cancel();
    await err.cancel();
    return ProcessOutcome(code, _killReason);
  }

  Future<void> kill(KillReason reason) async {
    if (_killed) return;
    _killed = true;
    _killReason = reason;
    await killTree(_process.pid);
    _process.kill(ProcessSignal.sigkill);
  }
}

Future<void> killTree(int pid) async {
  if (Platform.isWindows) {
    try {
      await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
    } catch (_) {}
  } else {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}

/// Runs a shell command line (cmd.exe on Windows) and captures its output.
Future<(int, String)> runShell(
  String commandLine,
  String workingDirectory, {
  Duration timeout = const Duration(minutes: 20),
}) async {
  final buffer = StringBuffer();
  final (proc, done) = await ManagedProcess.start(
    executable: Platform.isWindows ? 'cmd.exe' : '/bin/sh',
    args: Platform.isWindows ? ['/d', '/s', '/c', commandLine] : ['-c', commandLine],
    workingDirectory: workingDirectory,
    timeout: timeout,
    onLine: (line, _) => buffer.writeln(line),
  );
  final outcome = await done;
  if (outcome.killReason == KillReason.timeout) {
    buffer.writeln('[AutoLoop] Comando interrotto: superato il timeout di ${timeout.inMinutes} minuti.');
  }
  return (outcome.killReason == null ? outcome.exitCode : -1, buffer.toString());
}

/// Plain `git` invocation with captured output.
Future<ProcessResult> git(List<String> args, String dir) =>
    Process.run('git', args, workingDirectory: dir, stdoutEncoding: utf8, stderrEncoding: utf8);
