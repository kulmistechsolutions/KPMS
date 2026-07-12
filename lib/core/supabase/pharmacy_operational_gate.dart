import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/app_constants.dart';
import '../constants/app_prefs_keys.dart';

/// Cached result of [get_my_pharmacy_operational_status] for GoRouter (suspension, expiry, maintenance).
class PharmacyOperationalStatus {
  const PharmacyOperationalStatus({
    required this.blocked,
    this.reason,
    this.message,
    this.subscriptionWarning = false,
    this.subscriptionWarningMessage,
    this.featureFlags = const {},
    this.entitlements = const {},
    this.forceLogoutEpoch = 0,
  });

  final bool blocked;
  final String? reason;
  final String? message;

  /// Non-blocking warning (e.g. expiry soon, grace period).
  final bool subscriptionWarning;
  final String? subscriptionWarningMessage;

  /// Plan + tenant overrides: `false` disables a module (see app router mapping).
  final Map<String, dynamic> featureFlags;

  /// Limit snapshot from plan (may be null values).
  final Map<String, dynamic> entitlements;

  /// Server epoch; when greater than last-acked prefs, client signs out once.
  final int forceLogoutEpoch;

  factory PharmacyOperationalStatus.fromRpc(dynamic raw) {
    if (raw is! Map) {
      return const PharmacyOperationalStatus(blocked: false);
    }
    final m = Map<String, dynamic>.from(raw);
    final blocked = m['blocked'] == true;
    final reason = m['reason'] as String?;
    final message = m['message'] as String?;
    final subWarn = m['subscription_warning'] == true;
    final subMsg = m['subscription_warning_message'] as String?;

    Map<String, dynamic> ff = {};
    final ffRaw = m['feature_flags'];
    if (ffRaw is Map) {
      ff = Map<String, dynamic>.from(ffRaw);
    }

    Map<String, dynamic> ent = {};
    final entRaw = m['entitlements'];
    if (entRaw is Map) {
      ent = Map<String, dynamic>.from(entRaw);
    }

    final fle = m['force_logout_epoch'];
    final epoch = fle is int ? fle : int.tryParse('$fle') ?? 0;

    return PharmacyOperationalStatus(
      blocked: blocked,
      reason: reason,
      message: message,
      subscriptionWarning: subWarn,
      subscriptionWarningMessage: subMsg,
      featureFlags: ff,
      entitlements: ent,
      forceLogoutEpoch: epoch,
    );
  }
}

class PharmacyOperationalGate {
  PharmacyOperationalGate._();

  static String? _userId;
  static PharmacyOperationalStatus? _status;
  static DateTime? _fetchedAt;
  static const _ttl = Duration(seconds: 8);

  static void invalidate() {
    _userId = null;
    _status = null;
    _fetchedAt = null;
  }

  static String _epochKey(String userId) => '${AppPrefsKeys.forceLogoutEpochAck}_$userId';

  static Future<PharmacyOperationalStatus> resolve(SupabaseClient client, String userId) async {
    final now = DateTime.now();
    if (_userId == userId &&
        _status != null &&
        _fetchedAt != null &&
        now.difference(_fetchedAt!) < _ttl) {
      return _status!;
    }
    try {
      final raw = await client
          .rpc('get_my_pharmacy_operational_status')
          .timeout(AppConstants.authGateNetworkTimeout);
      var parsed = PharmacyOperationalStatus.fromRpc(raw);

      final epoch = parsed.forceLogoutEpoch;
      if (!parsed.blocked && epoch > 0) {
        final prefs = await SharedPreferences.getInstance();
        final ack = prefs.getInt(_epochKey(userId)) ?? 0;
        if (epoch > ack) {
          await prefs.setInt(_epochKey(userId), epoch);
          await client.auth.signOut();
          invalidate();
          parsed = const PharmacyOperationalStatus(blocked: false);
        }
      }

      _status = parsed;
      _userId = userId;
      _fetchedAt = DateTime.now();
      return _status!;
    } catch (e, st) {
      debugPrint('PharmacyOperationalGate.resolve failed: $e\n$st');
      _status = const PharmacyOperationalStatus(blocked: false);
      _userId = userId;
      _fetchedAt = DateTime.now();
      return _status!;
    }
  }
}
