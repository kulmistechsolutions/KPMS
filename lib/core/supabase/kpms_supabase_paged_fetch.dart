import '../constants/app_constants.dart';
import '../performance/kpms_performance_log.dart';
import 'supabase_bootstrap.dart';

/// Fetches all rows for [table] with [tenantId] using bounded ranges (PostgREST default caps).
abstract final class KpmsSupabasePagedFetch {
  KpmsSupabasePagedFetch._();

  static const int defaultPageSize = 800;

  /// Stable ascending [orderColumn] required for deterministic paging (typically `id`).
  static Future<List<Map<String, dynamic>>> fetchAllForTenant({
    required String table,
    required String tenantId,
    String orderColumn = 'id',
    int pageSize = defaultPageSize,
  }) async {
    final c = SupabaseBootstrap.clientOrNull;
    if (c == null) return const [];

    final tid = tenantId.trim();
    if (tid.isEmpty) return const [];

    var from = 0;
    final acc = <Map<String, dynamic>>[];
    while (true) {
      final raw = await c
          .from(table)
          .select()
          .eq('tenant_id', tid)
          .order(orderColumn, ascending: true)
          .range(from, from + pageSize - 1)
          .timeout(AppConstants.workspacePullPageTimeout);

      final list = raw as List<dynamic>;
      if (list.isEmpty) break;
      for (final r in list) {
        if (r is Map) {
          final m = Map<String, dynamic>.from(r);
          if ('${m['tenant_id']}'.trim() == tid) acc.add(m);
        }
      }
      KpmsPerformanceLog.paginationLoaded(table: table, count: list.length, offset: from);
      if (list.length < pageSize) break;
      from += pageSize;
    }
    return acc;
  }

  /// Incremental pull when [since] is set (requires `updated_at` on table).
  static Future<List<Map<String, dynamic>>> fetchForTenantSince({
    required String table,
    required String tenantId,
    required DateTime since,
    String orderColumn = 'updated_at',
    int pageSize = defaultPageSize,
  }) async {
    final c = SupabaseBootstrap.clientOrNull;
    if (c == null) return const [];

    final tid = tenantId.trim();
    if (tid.isEmpty) return const [];

    final sinceIso = since.toUtc().toIso8601String();
    var from = 0;
    final acc = <Map<String, dynamic>>[];
    while (true) {
      final raw = await c
          .from(table)
          .select()
          .eq('tenant_id', tid)
          .gte(orderColumn, sinceIso)
          .order(orderColumn, ascending: true)
          .range(from, from + pageSize - 1)
          .timeout(AppConstants.workspacePullPageTimeout);

      final list = raw as List<dynamic>;
      if (list.isEmpty) break;
      for (final r in list) {
        if (r is Map) {
          final m = Map<String, dynamic>.from(r);
          if ('${m['tenant_id']}'.trim() == tid) acc.add(m);
        }
      }
      KpmsPerformanceLog.paginationLoaded(table: '$table@since', count: list.length, offset: from);
      if (list.length < pageSize) break;
      from += pageSize;
    }
    return acc;
  }
}
