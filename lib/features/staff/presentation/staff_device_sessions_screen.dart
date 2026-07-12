import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/kpms_feedback.dart';
import '../../../core/widgets/kpms_page_shell.dart';
import '../application/staff_providers.dart';

/// Lists device registrations for the signed-in user ([pharmacy_staff_device_sessions]).
class StaffDeviceSessionsScreen extends ConsumerWidget {
  const StaffDeviceSessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(myDeviceSessionsProvider);
    return KpmsPageShell(
      title: 'Active sessions',
      subtitle: 'Devices signed in to your account',
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e', textAlign: TextAlign.center)),
        data: (rows) {
          if (rows.isEmpty) {
            return Center(
              child: Text(
                'No session records yet. They appear after this device registers with the server.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 120),
            itemCount: rows.length,
            separatorBuilder: (_, index) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = rows[i];
              final revoked = r['revoked_at'] != null;
              final plat = '${r['platform'] ?? '—'}';
              final seen = '${r['last_seen_at'] ?? ''}';
              final id = '${r['id']}';
              return ListTile(
                title: Text('${r['device_id']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${revoked ? 'Revoked' : 'Active'} · $plat · last $seen',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: revoked
                    ? null
                    : TextButton(
                        onPressed: () async {
                          try {
                            await ref.read(staffRepositoryProvider).revokeDeviceSession(sessionId: id);
                            ref.invalidate(myDeviceSessionsProvider);
                            if (context.mounted) kpmsSnack(context, 'Session revoked');
                          } catch (e) {
                            if (context.mounted) kpmsSnack(context, '$e', isError: true);
                          }
                        },
                        child: const Text('Revoke'),
                      ),
              );
            },
          );
        },
      ),
    );
  }
}

// autoDispose: screen-scoped. Frees the list on exit and re-fetches fresh session
// data on re-entry (an active-device-sessions list should never serve a stale cache).
final myDeviceSessionsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(staffRepositoryProvider).listMyDeviceSessions();
});
