import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/widgets/kpms_empty_state.dart';
import '../../../core/widgets/kpms_platform_admin_shell.dart';
import '../application/platform_admin_providers.dart';
import 'widgets/pharmacy_admin_actions.dart';
import 'widgets/platform_admin_ui.dart';

class SuperAdminUsersScreen extends ConsumerStatefulWidget {
  const SuperAdminUsersScreen({super.key});

  @override
  ConsumerState<SuperAdminUsersScreen> createState() => _SuperAdminUsersScreenState();
}

class _SuperAdminUsersScreenState extends ConsumerState<SuperAdminUsersScreen> {
  final _search = TextEditingController();
  String _role = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _apply() {
    ref.read(superAdminUsersFilterProvider.notifier).state = (_search.text.trim(), _role, '');
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(superAdminFilteredUsersProvider);
    return KpmsPlatformAdminShell(
      title: 'Users',
      subtitle: 'Cross-tenant directory',
      contentMaxWidth: 1200,
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () {
            ref.invalidate(superAdminUsersProvider);
            ref.invalidate(superAdminFilteredUsersProvider);
          },
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < 720;
              final filters = [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      labelText: 'Search name or email',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _apply(),
                  ),
                ),
                const SizedBox(width: PlatformAdminSpacing.sm),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(_role),
                    initialValue: _role.isEmpty ? '' : _role,
                    decoration: const InputDecoration(labelText: 'Role', border: OutlineInputBorder(), isDense: true),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('All roles')),
                      DropdownMenuItem(value: 'pharmacy_owner', child: Text('pharmacy_owner')),
                      DropdownMenuItem(value: 'pharmacist', child: Text('pharmacist')),
                      DropdownMenuItem(value: 'cashier', child: Text('cashier')),
                      DropdownMenuItem(value: 'staff', child: Text('staff')),
                      DropdownMenuItem(value: 'super_admin', child: Text('super_admin')),
                    ],
                    onChanged: (v) => setState(() => _role = v ?? ''),
                  ),
                ),
              ];
              if (narrow) {
                return Column(
                  children: [
                    TextField(
                      controller: _search,
                      decoration: const InputDecoration(labelText: 'Search', border: OutlineInputBorder()),
                      onSubmitted: (_) => _apply(),
                    ),
                    const SizedBox(height: PlatformAdminSpacing.sm),
                    DropdownButtonFormField<String>(
                      key: ValueKey(_role),
                      initialValue: _role.isEmpty ? '' : _role,
                      decoration: const InputDecoration(labelText: 'Role', border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('All roles')),
                        DropdownMenuItem(value: 'pharmacy_owner', child: Text('pharmacy_owner')),
                        DropdownMenuItem(value: 'pharmacist', child: Text('pharmacist')),
                        DropdownMenuItem(value: 'cashier', child: Text('cashier')),
                        DropdownMenuItem(value: 'staff', child: Text('staff')),
                      ],
                      onChanged: (v) => setState(() => _role = v ?? ''),
                    ),
                    const SizedBox(height: PlatformAdminSpacing.sm),
                    FilledButton.tonal(onPressed: _apply, child: const Text('Apply filters')),
                  ],
                );
              }
              return Row(
                children: [
                  ...filters,
                  const SizedBox(width: PlatformAdminSpacing.sm),
                  FilledButton.tonal(onPressed: _apply, child: const Text('Apply')),
                ],
              );
            },
          ),
          const SizedBox(height: PlatformAdminSpacing.md),
          Expanded(
            child: async.when(
              loading: () => const PlatformSkeletonList(),
              error: (e, _) => KpmsEmptyState(icon: Icons.error_outline, title: 'Error', message: '$e'),
              data: (rows) {
                if (rows.isEmpty) {
                  return const KpmsEmptyState(icon: Icons.person_off_outlined, title: 'No users', message: 'Adjust filters.');
                }
                return ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: PlatformAdminSpacing.sm),
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    final tenantId = r['tenant_id']?.toString();
                    return Card(
                      child: ListTile(
                        title: Text(r['full_name']?.toString() ?? r['account_email']?.toString() ?? 'User'),
                        subtitle: Text(
                          '${r['role'] ?? ''} · ${r['pharmacy_name'] ?? 'No pharmacy'}\n${r['account_email'] ?? ''}',
                        ),
                        isThreeLine: true,
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'pharmacy' && tenantId != null) {
                              context.push(AppRoutes.superAdminPharmacyDetail(tenantId));
                            } else if (v == 'force' && tenantId != null) {
                              await PharmacyAdminActions.forceLogout(context, ref, tenantId);
                            }
                          },
                          itemBuilder: (ctx) => [
                            if (tenantId != null) const PopupMenuItem(value: 'pharmacy', child: Text('Open pharmacy')),
                            if (tenantId != null) const PopupMenuItem(value: 'force', child: Text('Force logout tenant')),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
