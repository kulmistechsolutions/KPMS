import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_bootstrap.dart';

/// Tenant + platform billing RPCs and WAAFI edge function calls.
class BillingRepository {
  const BillingRepository();

  SupabaseClient? get _c => SupabaseBootstrap.clientOrNull;

  Future<Map<String, dynamic>> createCheckout({
    required String planId,
    String billingInterval = 'monthly',
    String? couponCode,
    required String payerMobile,
  }) async {
    final res = await _c!.functions.invoke(
      'waafi-init-payment',
      body: {
        'plan_id': planId,
        'billing_interval': billingInterval,
        'payer_mobile': payerMobile,
        if (couponCode != null && couponCode.isNotEmpty) 'coupon_code': couponCode,
      },
    );
    if (res.status != 200) {
      if (res.data is Map) {
        final map = Map<String, dynamic>.from(res.data as Map);
        final err = map['error']?.toString();
        if (err != null && err.isNotEmpty) throw Exception(err);
      }
      throw Exception('Payment initiation failed (${res.status})');
    }
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<List<Map<String, dynamic>>> myBillingHistory({int limit = 20}) async {
    final raw = await _c!.rpc('kpms_my_billing_history', params: {'p_limit': limit});
    if (raw is List) {
      return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList(growable: false);
    }
    return [];
  }

  Future<Map<String, dynamic>> billingAnalytics() async {
    final raw = await _c!.rpc('super_admin_billing_analytics');
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return {};
  }

  Future<({List<Map<String, dynamic>> rows, int total})> listPayments({
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final raw = await _c!.rpc(
      'super_admin_list_payments',
      params: {
        'p_status': status,
        'p_limit': limit,
        'p_offset': offset,
      },
    );
    final map = raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(raw as Map);
    final rowsRaw = map['rows'];
    final rows = rowsRaw is List
        ? rowsRaw.map((e) => Map<String, dynamic>.from(e as Map)).toList(growable: false)
        : <Map<String, dynamic>>[];
    return (rows: rows, total: (map['total'] as num?)?.toInt() ?? rows.length);
  }

  Future<void> recordManualPayment({
    required String tenantId,
    required String planId,
    required int amountCents,
    String billingInterval = 'monthly',
    String? note,
  }) async {
    await _c!.rpc(
      'super_admin_record_manual_payment',
      params: {
        'p_tenant_id': tenantId,
        'p_plan_id': planId,
        'p_amount_cents': amountCents,
        'p_billing_interval': billingInterval,
        'p_note': note,
      },
    );
  }

  Future<void> grantTrial({
    required String tenantId,
    required int days,
    String? reason,
  }) async {
    await _c!.rpc(
      'super_admin_grant_trial',
      params: {
        'p_tenant_id': tenantId,
        'p_days': days,
        'p_reason': reason,
      },
    );
  }

  Future<void> extendTrial({
    required String tenantId,
    required int extraDays,
    String? reason,
  }) async {
    await _c!.rpc(
      'super_admin_extend_trial',
      params: {
        'p_tenant_id': tenantId,
        'p_extra_days': extraDays,
        'p_reason': reason,
      },
    );
  }
}
