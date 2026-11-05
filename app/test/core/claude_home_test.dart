import 'package:claude_flow/core/claude_home.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveClaudeHome', () {
    test('CLAUDE_HOME wins, then the parent of WORKFLOW_ROOT, then HOME/.claude', () {
      expect(resolveClaudeHome(claudeHomeDefine: '/c', workflowRootDefine: '/w/workflow', home: '/h'), '/c');
      expect(resolveClaudeHome(claudeHomeDefine: '', workflowRootDefine: '/w/workflow/', home: '/h'), '/w');
      expect(resolveClaudeHome(claudeHomeDefine: '', workflowRootDefine: '', home: '/h'), '/h/.claude');
    });
  });

  group('effectiveEngineDir', () {
    const config = DashboardConfig(engineDir: '~/eng/');

    test('define beats config; ~/ expands and the trailing slash goes', () {
      expect(effectiveEngineDir(engineDirDefine: '', config: config, home: '/h'), '/h/eng');
      expect(effectiveEngineDir(engineDirDefine: '/d/', config: config, home: '/h'), '/d');
      expect(effectiveEngineDir(engineDirDefine: '', config: DashboardConfig.empty, home: '/h'), isNull);
      expect(effectiveEngineDir(engineDirDefine: '', config: config, home: null), '~/eng');
    });
  });
}
