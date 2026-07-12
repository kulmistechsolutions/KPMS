import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/kpms_permission_gate.dart';
import '../constants/app_constants.dart';
import '../monitoring/kpms_auth_health_metrics.dart';
import '../observability/kpms_auth_diagnostics.dart';
import '../persistence/kpms_persistence_log.dart';
import '../persistence/kpms_tenant_session_secure_store.dart';
import 'pharmacy_operational_gate.dart';

/// Caches whether the current auth user has `profiles.tenant_id` set (avoids repeated reads in GoRouter).
///
/// **Important:** Do not call [SupabaseClient.auth.refreshSession] here. Repeated refreshes hit Auth
/// rate limits (429), corrupt web sessions, and unauthenticated PostgREST reads return no `profiles` row.
class ProfileTenantGate {
  ProfileTenantGate._();

  static String? _userId;
  static bool? _hasTenant;

  /// Last successful tenant link per user (survives transient PostgREST / network errors).
  static final Map<String, bool> _lastKnownHasTenant = {};

  /// Resolved `profiles.tenant_id` (or RPC/snapshot) for workspace loaders.
  static final Map<String, String> _lastKnownTenantId = {};

  static final Map<String, String> _lastKnownProfileFullName = {};

  /// Deduplicate concurrent [hasTenantLinked] calls (GoRouter + widgets).
  static final Map<String, Future<bool>> _inFlight = {};

  /// Clears in-memory route caches only. Preserves [_lastKnownHasTenant] and secure snapshot
  /// so brief "no session" routing passes do not destroy tenant recovery hints.
  static void invalidateTransientRoutingState() {
    _userId = null;
    _hasTenant = null;
    KpmsPermissionGate.invalidate();
    PharmacyOperationalGate.invalidate();
    KpmsAuthDiagnostics.log('tenant_gate_transient_invalidate');
  }

  /// Full reset: memory sticky map, permission/operational gates, in-memory session cache.
  /// Does **not** clear [KpmsTenantSessionSecureStore] — call [KpmsTenantSessionSecureStore.clear]
  /// from [AuthRepository.signOut] only.
  static void invalidate() {
    _userId = null;
    _hasTenant = null;
    _lastKnownHasTenant.clear();
    _lastKnownTenantId.clear();
    _lastKnownProfileFullName.clear();
    _inFlight.clear();
    KpmsPermissionGate.invalidate();
    PharmacyOperationalGate.invalidate();
    KpmsAuthDiagnostics.log('tenant_gate_full_invalidate');
  }

  /// Call right after a successful `register_pharmacy` so the next redirect does not race the DB read.
  static void markTenantLinked(String userId, {String? tenantId}) {
    _userId = userId;
    _hasTenant = true;
    _lastKnownHasTenant[userId] = true;
    final tid = tenantId?.trim();
    if (tid != null && tid.isNotEmpty) {
      _lastKnownTenantId[userId] = tid;
    }
  }

  /// Tenant id + display name for settings/session providers (uses same recovery as routing).
  /// Last resolved tenant id for [userId] (memory / snapshot). Safe for workspace restore timeouts.
  static String? cachedTenantId(String userId) {
    final tid = _lastKnownTenantId[userId]?.trim();
    if (tid != null && tid.isNotEmpty) return tid;
    return null;
  }

  static Future<({String tenantId, String? profileFullName})?> resolveWorkspaceBinding(
    SupabaseClient client,
    String userId,
  ) async {
    final linked = await hasTenantLinked(client, userId);
    if (!linked) return null;

    var tid = _lastKnownTenantId[userId]?.trim();
    if (tid == null || tid.isEmpty) {
      final snap = await KpmsTenantSessionSecureStore.read();
      if (snap != null && snap.userId == userId && snap.tenantId.trim().isNotEmpty) {
        tid = snap.tenantId.trim();
        _lastKnownTenantId[userId] = tid;
      }
    }
    if (tid == null || tid.isEmpty) {
      final viaRpc = await _tryTenantViaAuthProfileTenantIdRpc(client);
      if (viaRpc != null && viaRpc.isNotEmpty) {
        tid = viaRpc;
        _lastKnownTenantId[userId] = tid;
      }
    }
    if (tid == null || tid.isEmpty) return null;

    final name = _lastKnownProfileFullName[userId];
    return (tenantId: tid, profileFullName: name);
  }

  static Future<bool> hasTenantLinked(SupabaseClient client, String userId) {
    return _inFlight.putIfAbsent(
      userId,
      () => _resolveHasTenantLinked(client, userId).whenComplete(() {
        _inFlight.remove(userId);
      }),
    );
  }

  static Future<bool> _resolveHasTenantLinked(SupabaseClient client, String userId) async {
    if (client.auth.currentSession == null) {
      KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'no_session', 'user': _shortId(userId)});
      debugPrint('ProfileTenantGate: no auth session');
      return false;
    }

    if (_userId == userId && _hasTenant != null) {
      KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'memory_hit', 'has': _hasTenant, 'user': _shortId(userId)});
      return _hasTenant!;
    }

    await _hydrateStickyFromSecureSnapshot(userId);

    // Fast path only when we already know the tenant id (routing + workspace loaders).
    final cachedTid = _lastKnownTenantId[userId]?.trim();
    if (_lastKnownHasTenant[userId] == true && cachedTid != null && cachedTid.isNotEmpty) {
      _userId = userId;
      _hasTenant = true;
      KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'sticky_fast_path', 'user': _shortId(userId)});
      KpmsPersistenceLog.tenantSnapshotHydrated(cachedTid);
      return true;
    }

    try {
      try {
        await client.rpc('ensure_my_profile').timeout(AppConstants.authGateNetworkTimeout);
        KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'ensure_my_profile_ok', 'user': _shortId(userId)});
      } catch (e) {
        KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'ensure_my_profile_skip', 'err': '$e'});
      }

      Map<String, dynamic>? lastRow;
      const maxAttempts = 5;
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        if (attempt > 0) {
          final ms = (150 * (1 << (attempt - 1))).clamp(150, 2000);
          await Future<void>.delayed(Duration(milliseconds: ms));
        }

        KpmsAuthDiagnostics.log('tenant_restore', {
          'stage': 'profiles_select',
          'attempt': attempt + 1,
          'user': _shortId(userId),
        });

        final row = await client
            .from('profiles')
            .select('tenant_id, role, full_name')
            .eq('id', userId)
            .maybeSingle()
            .timeout(AppConstants.authGateNetworkTimeout);

        lastRow = row;
        if (row != null) {
          final outcome = _applyProfileRow(userId, row);
          await _persistSnapshotIfLinked(userId, row, outcome);
          KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'profiles_resolved', 'has': outcome});
          return outcome;
        }
      }

      KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'rpc_fallback', 'user': _shortId(userId)});
      final viaPerm = await _tryTenantViaPermissionProfileRpc(client);
      if (viaPerm != null) {
        KpmsAuthHealthMetrics.onTenantRpcFallback('kpms_my_permission_profile');
        final effective = _finalizeEffective(userId, hasFromDb: viaPerm.$1, row: viaPerm.$2);
        await _persistSnapshotIfLinked(userId, viaPerm.$2, effective);
        return effective;
      }

      final viaDefiner = await _tryTenantViaAuthProfileTenantIdRpc(client);
      if (viaDefiner != null && viaDefiner.isNotEmpty) {
        KpmsAuthHealthMetrics.onTenantRpcFallback('kpms_auth_profile_tenant_id');
        final synthetic = <String, dynamic>{
          'tenant_id': viaDefiner,
          'role': lastRow?['role'],
          'full_name': lastRow?['full_name'],
        };
        final effective = _finalizeEffective(userId, hasFromDb: true, row: synthetic);
        await _persistSnapshotIfLinked(userId, synthetic, effective);
        return effective;
      }

      KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'profile_row_missing', 'user': _shortId(userId)});
      if (_lastKnownHasTenant[userId] == true) {
        _userId = userId;
        _hasTenant = true;
        KpmsAuthHealthMetrics.onTenantStickyRecovery('profile_row_missing');
        KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'sticky_row_missing', 'user': _shortId(userId)});
        return true;
      }
      _userId = userId;
      _hasTenant = false;
      _lastKnownHasTenant[userId] = false;
      KpmsAuthHealthMetrics.onTenantRestoreFailure('no_tenant_confirmed');
      return false;
    } catch (e, st) {
      KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'error', 'err': '$e', 'user': _shortId(userId)});
      debugPrint('ProfileTenantGate.hasTenantLinked failed: $e\n$st');
      final sticky = _lastKnownHasTenant[userId];
      if (sticky == true) {
        _userId = userId;
        _hasTenant = true;
        KpmsAuthHealthMetrics.onTenantStickyRecovery('post_exception');
        KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'sticky_after_error', 'user': _shortId(userId)});
        return true;
      }
      KpmsAuthHealthMetrics.onTenantRestoreFailure('exception_no_sticky');
      return false;
    }
  }

  static String _shortId(String id) {
    if (id.length <= 10) return id;
    return id.substring(0, 8);
  }

  static Future<void> _hydrateStickyFromSecureSnapshot(String userId) async {
    final snap = await KpmsTenantSessionSecureStore.read();
    if (snap == null) return;
    if (snap.userId != userId) return;
    if (snap.tenantId.trim().isEmpty) return;
    _lastKnownHasTenant[userId] = true;
    _lastKnownTenantId[userId] = snap.tenantId.trim();
    final name = snap.pharmacyName?.trim();
    if (name != null && name.isNotEmpty) {
      _lastKnownProfileFullName[userId] = name;
    }
    KpmsAuthHealthMetrics.onTenantStickyRecovery('secure_snapshot');
    KpmsPersistenceLog.tenantSnapshotHydrated(snap.tenantId.trim());
    KpmsAuthDiagnostics.log('tenant_restore', {
      'stage': 'secure_snapshot_hydrate',
      'user': _shortId(userId),
      'age_ms': DateTime.now().millisecondsSinceEpoch - snap.savedAtMs,
    });
  }

  static bool _applyProfileRow(String userId, Map<String, dynamic> row) {
    final tid = row['tenant_id'];
    final has = tid != null && '$tid'.trim().isNotEmpty;
    if (has) {
      _lastKnownHasTenant[userId] = true;
      _lastKnownTenantId[userId] = '$tid'.trim();
      final fn = row['full_name'];
      if (fn != null && '$fn'.trim().isNotEmpty) {
        _lastKnownProfileFullName[userId] = '$fn'.trim();
      }
    } else if (_lastKnownHasTenant[userId] != true) {
      _lastKnownHasTenant[userId] = false;
    }
    final effective = has || (_lastKnownHasTenant[userId] == true);
    _userId = userId;
    _hasTenant = effective;
    return effective;
  }

  static bool _finalizeEffective(String userId, {required bool hasFromDb, required Map<String, dynamic>? row}) {
    if (hasFromDb) {
      _lastKnownHasTenant[userId] = true;
      final tid = row?['tenant_id'];
      if (tid != null && '$tid'.trim().isNotEmpty) {
        _lastKnownTenantId[userId] = '$tid'.trim();
      }
      final fn = row?['full_name'];
      if (fn != null && '$fn'.trim().isNotEmpty) {
        _lastKnownProfileFullName[userId] = '$fn'.trim();
      }
    } else if (_lastKnownHasTenant[userId] != true) {
      _lastKnownHasTenant[userId] = false;
    }
    final effective = hasFromDb || (_lastKnownHasTenant[userId] == true);
    _userId = userId;
    _hasTenant = effective;
    return effective;
  }

  static Future<void> _persistSnapshotIfLinked(
    String userId,
    Map<String, dynamic>? row,
    bool effective,
  ) async {
    if (!effective || row == null) return;
    final tid = row['tenant_id'];
    if (tid == null || '$tid'.trim().isEmpty) return;
    final role = row['role'] as String?;
    final name = row['full_name'] as String?;
    await KpmsTenantSessionSecureStore.write(
      KpmsTenantSessionSnapshot(
        userId: userId,
        tenantId: '$tid'.trim(),
        role: role,
        pharmacyName: name,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'secure_snapshot_persisted', 'user': _shortId(userId)});
  }

  static Future<(bool, Map<String, dynamic>)?> _tryTenantViaPermissionProfileRpc(SupabaseClient client) async {
    try {
      final raw = await client
          .rpc('kpms_my_permission_profile')
          .timeout(AppConstants.authGateNetworkTimeout);
      if (raw == null || raw is! Map) return null;
      final m = Map<String, dynamic>.from(raw);
      final tid = m['tenant_id'];
      final has = tid != null && '$tid'.trim().isNotEmpty;
      if (!has) return null;
      return (true, m);
    } catch (e) {
      KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'rpc_perm_profile_fail', 'err': '$e'});
      return null;
    }
  }

  static Future<String?> _tryTenantViaAuthProfileTenantIdRpc(SupabaseClient client) async {
    try {
      final raw = await client
          .rpc('kpms_auth_profile_tenant_id')
          .timeout(AppConstants.authGateNetworkTimeout);
      if (raw == null) return null;
      final s = '$raw'.trim();
      return s.isEmpty ? null : s;
    } catch (e) {
      KpmsAuthDiagnostics.log('tenant_restore', {'stage': 'rpc_auth_tenant_id_fail', 'err': '$e'});
      return null;
    }
  }
}
