import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_routes.dart';
import '../../../../core/utils/kpms_feedback.dart';
import '../../application/platform_admin_providers.dart';
/// Shared operator actions for pharmacy rows and detail screens.
abstract final class PharmacyAdminActions {
  static Future<void> viewPharmacy(BuildContext context, String tenantId) {
    return context.push(AppRoutes.superAdminPharmacyDetail(tenantId));
  }

  static Future<void> editPharmacy(
    BuildContext context,
    WidgetRef ref,
    String tenantId,
    Map<String, dynamic> tenant,
  ) async {
    final name = TextEditingController(text: tenant['name']?.toString() ?? '');
    final address = TextEditingController(text: tenant['address']?.toString() ?? '');
    final phone = TextEditingController(text: tenant['phone']?.toString() ?? '');
    final license = TextEditingController(text: tenant['license_number']?.toString() ?? '');
    final owner = TextEditingController(text: tenant['owner_name']?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit pharmacy'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(controller: address, decoration: const InputDecoration(labelText: 'Address', border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone', border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(controller: license, decoration: const InputDecoration(labelText: 'License', border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(controller: owner, decoration: const InputDecoration(labelText: 'Owner name', border: OutlineInputBorder())),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(platformAdminRepositoryProvider).updatePharmacy(
            tenantId: tenantId,
            name: name.text.trim(),
            address: address.text.trim(),
            phone: phone.text.trim(),
            license: license.text.trim(),
            ownerName: owner.text.trim(),
          );
      _invalidate(ref, tenantId);
      if (!context.mounted) return;
      kpmsSnack(context, 'Pharmacy updated.');
    } catch (e) {
      if (!context.mounted) return;
      kpmsSnack(context, '$e', isError: true);
    }
  }

  static Future<void> suspend(
    BuildContext context,
    WidgetRef ref,
    String tenantId, {
    Map<String, dynamic>? row,
  }) async {
    final reason = TextEditingController();
    final until = ValueNotifier<DateTime?>(null);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Suspend pharmacy'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Staff sign-in and sync will be blocked until reactivated. Data is not deleted.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              decoration: const InputDecoration(labelText: 'Reason (audit log)', border: OutlineInputBorder()),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<DateTime?>(
              valueListenable: until,
              builder: (context, date, _) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(date == null ? 'Duration: until manual reactivation' : 'Auto-review: ${date.toLocal()}'),
                trailing: TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) until.value = picked;
                  },
                  child: const Text('Set date'),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Suspend'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final detail = [
        if (reason.text.trim().isNotEmpty) reason.text.trim(),
        if (until.value != null) 'review_until=${until.value!.toIso8601String()}',
      ].join(' · ');
      await ref.read(platformAdminRepositoryProvider).suspendPharmacy(tenantId, detail.isEmpty ? null : detail);
      if (!context.mounted) return;
      _invalidate(ref, tenantId);
      kpmsSnack(context, 'Pharmacy suspended.');
    } catch (e) {
      if (!context.mounted) return;
      kpmsSnack(context, '$e', isError: true);
    }
  }

  static Future<void> reactivate(BuildContext context, WidgetRef ref, String tenantId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Activate pharmacy'),
        content: const Text('Restores staff access subject to subscription status.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Activate')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(platformAdminRepositoryProvider).reactivatePharmacy(tenantId);
      if (!context.mounted) return;
      _invalidate(ref, tenantId);
      kpmsSnack(context, 'Pharmacy activated.');
    } catch (e) {
      if (!context.mounted) return;
      kpmsSnack(context, '$e', isError: true);
    }
  }

  static Future<void> archiveSoftDelete(BuildContext context, WidgetRef ref, String tenantId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Archive pharmacy?'),
        content: const Text('Soft-deletes the tenant in the directory. Use reactivation support via database restore if needed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Archive')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(platformAdminRepositoryProvider).archivePharmacy(tenantId);
      ref.invalidate(superAdminPharmaciesProvider);
      if (!context.mounted) return;
      kpmsSnack(context, 'Pharmacy archived.');
      context.go(AppRoutes.superAdminPharmacies);
    } catch (e) {
      if (!context.mounted) return;
      kpmsSnack(context, '$e', isError: true);
    }
  }

  static Future<void> forceLogout(BuildContext context, WidgetRef ref, String tenantId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Force logout all staff?'),
        content: const Text('Devices sign out on next operational status check.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Force logout')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(platformAdminRepositoryProvider).forceLogoutTenant(tenantId);
      if (!context.mounted) return;
      kpmsSnack(context, 'Force logout issued.');
    } catch (e) {
      if (!context.mounted) return;
      kpmsSnack(context, '$e', isError: true);
    }
  }

  static Future<void> resetSyncCache(BuildContext context, WidgetRef ref, String tenantId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset sync / cache signal'),
        content: const Text(
          'Marks the tenant for account reset follow-up and forces staff logout so devices refresh operational state.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(platformAdminRepositoryProvider).resetPharmacyAccount(tenantId);
      await ref.read(platformAdminRepositoryProvider).forceLogoutTenant(tenantId);
      if (!context.mounted) return;
      kpmsSnack(context, 'Reset signal sent; staff will refresh on next check.');
    } catch (e) {
      if (!context.mounted) return;
      kpmsSnack(context, '$e', isError: true);
    }
  }

  static void manageSubscription(BuildContext context, String tenantId) {
    context.push('${AppRoutes.superAdminPharmacyDetail(tenantId)}?tab=subscription');
  }

  static void viewAnalytics(BuildContext context, String tenantId) {
    context.push('${AppRoutes.superAdminPharmacyDetail(tenantId)}?tab=overview');
  }

  static void viewStaff(BuildContext context, String tenantId) {
    context.push('${AppRoutes.superAdminPharmacyDetail(tenantId)}?tab=staff');
  }

  static void viewAudit(BuildContext context, WidgetRef ref, String tenantId) {
    ref.read(superAdminAuditFilterProvider.notifier).state = ('', tenantId, 90);
    context.push(AppRoutes.superAdminAudit);
  }

  static void sendAnnouncement(BuildContext context) {
    context.push(AppRoutes.superAdminAnnouncements);
  }

  static void _invalidate(WidgetRef ref, String tenantId) {
    ref.invalidate(superAdminPharmacyDetailProvider(tenantId));
    ref.invalidate(superAdminPharmaciesProvider);
    ref.invalidate(superAdminPharmacyStatsProvider(tenantId));
  }
}
