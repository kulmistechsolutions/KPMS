import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/widgets/kpms_platform_admin_shell.dart';
import '../application/platform_admin_providers.dart';
import 'widgets/platform_admin_ui.dart';

/// Registration queue — pharmacies created in the last 30 days pending review.
class SuperAdminApprovalsScreen extends ConsumerWidget {
  const SuperAdminApprovalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(superAdminPharmaciesProvider);
    return KpmsPlatformAdminShell(
      title: 'Approvals',
      subtitle: 'Recent pharmacy registrations',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () {
            ref.read(superAdminPharmacyDirectoryQueryProvider.notifier).state = ('', 'active');
            ref.invalidate(superAdminPharmaciesProvider);
          },
        ),
      ],
      body: async.when(
        loading: () => const PlatformSkeletonList(),
        error: (e, _) => Center(child: Text('$e')),
        data: (rows) {
          final cutoff = DateTime.now().subtract(const Duration(days: 30));
          final pending = rows.where((r) {
            final created = DateTime.tryParse(r['created_at']?.toString() ?? '');
            if (created == null) return false;
            return created.isAfter(cutoff);
          }).toList()
            ..sort((a, b) => (b['created_at']?.toString() ?? '').compareTo(a['created_at']?.toString() ?? ''));

          if (pending.isEmpty) {
            return const Center(child: Text('No new registrations in the last 30 days.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.only(bottom: PlatformAdminSpacing.xl),
            itemCount: pending.length,
            separatorBuilder: (_, _) => const SizedBox(height: PlatformAdminSpacing.sm),
            itemBuilder: (context, i) {
              final r = pending[i];
              final id = r['tenant_id']?.toString();
              return Card(
                child: ListTile(
                  title: Text(r['pharmacy_name']?.toString() ?? '—'),
                  subtitle: Text('${r['owner_email'] ?? ''}\nRegistered ${r['created_at'] ?? ''}'),
                  isThreeLine: true,
                  trailing: FilledButton.tonal(
                    onPressed: id == null ? null : () => context.push(AppRoutes.superAdminPharmacyDetail(id)),
                    child: const Text('Review'),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
