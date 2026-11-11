import 'package:auto_loop/demo.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/loop_state.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('demo data loads with mixed block states and never runs an agent', () async {
    final demo = await DemoData.create();
    final engine = LoopEngine(LoopSettings())..demo = true;
    expect(engine.load(workDir: demo.workDir, planPath: demo.planPath), isNull);
    final states = [for (final b in engine.plan!.blocks) engine.blockState(b).status];
    expect(states, [
      BlockStatus.done,
      BlockStatus.done,
      BlockStatus.done,
      BlockStatus.blocked,
      BlockStatus.pending,
      BlockStatus.pending,
    ]);
    expect(engine.totalTime.inMinutes, 134);

    await engine.start();
    expect(engine.phase, LoopPhase.idle);
    expect(engine.state!.runs, 9); // unchanged: nothing was invoked
  });
}
