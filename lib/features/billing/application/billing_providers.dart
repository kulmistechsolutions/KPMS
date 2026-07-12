import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/billing_repository.dart';

final billingRepositoryProvider = Provider<BillingRepository>((ref) => const BillingRepository());

final myBillingHistoryProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(billingRepositoryProvider).myBillingHistory();
});

final superAdminBillingAnalyticsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) {
  return ref.watch(billingRepositoryProvider).billingAnalytics();
});

final superAdminPaymentsProvider = FutureProvider.autoDispose
    .family<({List<Map<String, dynamic>> rows, int total}), String?>((ref, status) {
  return ref.watch(billingRepositoryProvider).listPayments(status: status);
});
