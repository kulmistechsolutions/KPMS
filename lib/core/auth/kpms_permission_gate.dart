import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/app_constants.dart';
import 'kpms_permission_context.dart';
import 'kpms_permission_revoke_sync.dart';

/// Loads and caches [KpmsPermissionContext] for the active user (mirrors [ProfileTenantGate] pattern).
class KpmsPermissionGate {
  KpmsPermissionGate._();

  static String? _userId;
  static KpmsPermissionContext? _context;

  static void invalidate() {
    _userId = null;
    _context = null;
  }

  /// Marks context as linked without DB round-trip (e.g. after role RPC).
  static void seedForSession(String userId, KpmsPermissionContext ctx) {
    _userId = userId;
    _context = ctx;
  }

  static Future<KpmsPermissionContext> resolve(SupabaseClient client, String userId) async {
    if (_userId == userId && _context != null) {
      return _context!;
    }

    try {
      await client.rpc('ensure_my_profile').timeout(AppConstants.authGateNetworkTimeout);
    } catch (_) {}

    Map<String, dynamic>? row;
    try {
      final raw = await client
          .rpc('kpms_my_permission_profile')
          .timeout(AppConstants.authGateNetworkTimeout);
      if (raw != null && raw is Map) {
        final m = Map<String, dynamic>.from(raw);
        final r = m['role'];
        if (r != null && '$r'.trim().isNotEmpty) {
          row = m;
        }
      }
    } catch (e, st) {
      debugPrint('kpms_my_permission_profile unavailable, using profiles select: $e\n$st');
    }

    try {
      row ??= await client
          .from('profiles')
          .select('role, tenant_id, permissions, staff_status, permission_revoke_nonce, must_change_password')
          .eq('id', userId)
          .maybeSingle()
          .timeout(AppConstants.authGateNetworkTimeout);
      _context = KpmsPermissionContext.fromProfileRow(row);
      _userId = userId;
      await KpmsPermissionRevokeSync.applyAfterResolve(userId, _context!);
      if (client.auth.currentSession == null) {
        invalidate();
        return KpmsPermissionContext.fromProfileRow(null);
      }
      return _context!;
    } catch (e, st) {
      debugPrint('KpmsPermissionGate.resolve failed: $e\n$st');
      _context = KpmsPermissionContext.fromProfileRow(null);
      _userId = userId;
      return _context!;
    }
  }
}
