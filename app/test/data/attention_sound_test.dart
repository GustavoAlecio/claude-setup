import 'package:claude_flow/data/attention.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:flutter_test/flutter_test.dart';

AttentionItem _pending(String id, int n) => AttentionItem(
  key: 'pending:$id:$n',
  title: 't',
  body: 'b',
  route: '/',
  kind: AttentionKind.request,
  sessionId: id,
  pending: n,
);

AttentionItem _blocked(String k) =>
    AttentionItem(key: 'blocked:$k', title: 't', body: 'b', route: '/', kind: AttentionKind.blocked);

SessionSummary _session(String id, int pending) => SessionSummary(
  id: id,
  project: 'demo-app',
  command: 'c',
  title: 't',
  status: SessionStatus.waitingPermission,
  createdAt: '',
  pendingPermissions: pending,
);

final _t0 = DateTime.utc(2026, 1, 1, 12);

void main() {
  group('shouldSound', () {
    const empty = AttentionSnapshot(pending: {}, blocked: {});

    test('first load (null before) does not sound', () {
      expect(shouldSound(null, [_pending('a', 1), _blocked('p:r:T1')], at: _t0), isFalse);
    });

    test('a new session with pending requests sounds (absent counts as 0)', () {
      expect(shouldSound(empty, [_pending('a', 1)], at: _t0), isTrue);
    });

    test('a pending count that rises sounds', () {
      final before = AttentionSnapshot.of([_pending('a', 1)]);
      expect(shouldSound(before, [_pending('a', 2)], at: _t0), isTrue);
    });

    test('a pending count that falls or stays does not sound', () {
      final before = AttentionSnapshot.of([_pending('a', 2), _pending('b', 1)]);
      expect(shouldSound(before, [_pending('a', 1), _pending('b', 1)], at: _t0), isFalse);
      expect(shouldSound(before, [_pending('a', 2)], at: _t0), isFalse);
    });

    test('a new blocked key sounds, a known one does not', () {
      final before = AttentionSnapshot.of([_blocked('p:r1:T1')]);
      expect(shouldSound(before, [_blocked('p:r1:T1')], at: _t0), isFalse);
      expect(shouldSound(before, [_blocked('p:r1:T1'), _blocked('p:r2:T2')], at: _t0), isTrue);
    });

    test('an item that vanished and came back sounds again', () {
      final gone = AttentionSnapshot.of(const []);
      expect(shouldSound(gone, [_pending('a', 1)], at: _t0), isTrue);
    });

    test('a null lastSound does not block', () {
      expect(shouldSound(empty, [_pending('a', 1)], lastSound: null, at: _t0), isTrue);
    });

    test('inside the interval it does not sound, at the interval it does', () {
      final items = [_pending('a', 1)];
      expect(shouldSound(empty, items, lastSound: _t0, at: _t0.add(const Duration(milliseconds: 2999))), isFalse);
      expect(shouldSound(empty, items, lastSound: _t0, at: _t0.add(kSoundInterval)), isTrue);
    });

    test('kSoundInterval is 3 seconds', () {
      expect(kSoundInterval, const Duration(seconds: 3));
    });
  });

  group('AttentionSnapshot.of', () {
    test('a session id with colons keeps the whole id', () {
      final snap = AttentionSnapshot.of([_pending('a:b:c', 4), _blocked('p:r:T1')]);
      expect(snap.pending, {'a:b:c': 4});
      expect(snap.blocked, {'blocked:p:r:T1'});
    });

    test('round trip over pendingAttention', () {
      final items = pendingAttention([
        _session('a', 2),
        _session('b:x', 1),
        _session('c', 0),
      ], MockFlowRepository().projects);
      final snap = AttentionSnapshot.of(items);
      expect(snap.pending, {'a': 2, 'b:x': 1});
      expect(snap.blocked, {'blocked:demo-app:impl-20261001T141210Z:T4'});
    });
  });
}
