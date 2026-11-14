import 'package:auto_loop/demo.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/loop_state.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('demo data loads with mixed block states and never runs an agent', () async {
    final demo = await DemoData.create(folder: 'autoloop-demo-demo-test');
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
    expect(engine.logs, hasLength(demo.logs.length)); // loaded from the demo's saved history

    await engine.start();
    expect(engine.phase, LoopPhase.idle);
    expect(engine.state!.runs, 9); // unchanged: nothing was invoked
 
    // The demo menu shows made-up states; leaving "completed" restores the blocks.
    engine.demoShow(LoopPhase.running, block: 4);
    expect(engine.isActive, isTrue);
    expect(engine.currentBlock, 4);
    engine.demoShow(LoopPhase.finished, allDone: true);
    expect(engine.doneCount, 6);
    engine.demoShow(LoopPhase.idle);
    expect([for (final b in engine.plan!.blocks) engine.blockState(b).status], states);
    expect(engine.state!.runs, 9);
  });
}
