import '../engine/engine_config.dart';
import 'models.dart';
import 'orgs.dart';
import 'session_models.dart';

/// What the engine's sessions of [project] cost since [cycle] started, plus the sessions its report names. Without a
/// start date nothing is counted: summing every session the project ever had would blame the cycle for older work.
double cycleCost(Cycle cycle, String project, List<SessionSummary> sessions) {
  final since = cycle.startedAt;
  if (since == null) return 0;
  // A conversation that turned into the cycle with `/kickoff` was created before it began.
  final stageSessions = {...?cycle.report?.stages.map((s) => s.sessionId).nonNulls};
  var total = 0.0;
  for (final s in sessions) {
    if (stageSessions.contains(s.id)) {
      total += s.cost;
      continue;
    }
    if (s.isOrgSession || s.project != project) continue;
    final at = DateTime.tryParse(s.createdAt);
    if (at != null && !at.isBefore(since)) total += s.cost;
  }
  return total;
}

/// The org's budget per cycle, else the global one; `null` means no budget.
double? cycleBudgetFor(String? org, DashboardConfig? config) =>
    (org == null ? null : orgConfigOf(config, org)?.cycleBudget) ?? config?.cycleBudget;

enum BudgetState { none, ok, near, over }

/// `near` from 80% of the budget on, `over` at or past it.
BudgetState budgetState(double cost, double? budget) => switch (budget) {
  null => BudgetState.none,
  final b when cost >= b => BudgetState.over,
  final b when cost >= b * 0.8 => BudgetState.near,
  _ => BudgetState.ok,
};

String usd(double value) => '\$${value.toStringAsFixed(2)}';
