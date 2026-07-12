import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/utils/kpms_feedback.dart';
import '../../../core/widgets/kpms_platform_admin_shell.dart';
import '../application/platform_admin_providers.dart';
import 'widgets/pharmacy_admin_actions.dart';
import 'widgets/platform_admin_ui.dart';

/// Operator pharmacy control center — tabbed detail without changing backend contracts.
class SuperAdminPharmacyDetailScreen extends ConsumerStatefulWidget {
  const SuperAdminPharmacyDetailScreen({super.key, required this.tenantId});

  final String tenantId;

  @override
  ConsumerState<SuperAdminPharmacyDetailScreen> createState() => _SuperAdminPharmacyDetailScreenState();
}

class _SuperAdminPharmacyDetailScreenState extends ConsumerState<SuperAdminPharmacyDetailScreen> with SingleTickerProviderStateMixin {
  late TabController _tabs;

  static const _tabKeys = [
    'overview',
    'staff',
    'inventory',
    'sales',
    'revenue',
    'devices',
    'sync',
    'activity',
    'subscription',
    'settings',
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tabKeys.length, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tab = GoRouterState.of(context).uri.queryParameters['tab'];
    if (tab != null) {
      final i = _tabKeys.indexOf(tab);
      if (i >= 0 && _tabs.index != i) {
        _tabs.animateTo(i);
      }
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(superAdminPharmacyDetailProvider(widget.tenantId));
  final statsAsync = ref.watch(superAdminPharmacyStatsProvider(widget.tenantId));

    return async.when(
      loading: () => const KpmsPlatformAdminShell(
        title: 'Pharmacy',
        subtitle: 'Loading…',
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => KpmsPlatformAdminShell(
        title: 'Pharmacy',
        subtitle: 'Error',
        body: Center(child: Text('$e')),
      ),
      data: (bundle) {
        final t = bundle.tenant;
        if (t == null) {
          return KpmsPlatformAdminShell(
            title: 'Pharmacy',
            subtitle: 'Not found',
            body: Center(
              child: FilledButton(
                onPressed: () => context.go(AppRoutes.superAdminPharmacies),
                child: const Text('Back to directory'),
              ),
            ),
          );
        }
        final sub = bundle.subscription;
        final planMap = sub?['subscription_plans'] is Map ? Map<String, dynamic>.from(sub!['subscription_plans'] as Map) : null;
        final suspended = t['suspended_at'] != null;
        final archived = t['deleted_at'] != null;

        return KpmsPlatformAdminShell(
          title: t['name']?.toString() ?? 'Pharmacy',
          subtitle: 'Tenant ${widget.tenantId}',
          contentMaxWidth: 1320,
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: () {
                ref.invalidate(superAdminPharmacyDetailProvider(widget.tenantId));
                ref.invalidate(superAdminPharmacyStatsProvider(widget.tenantId));
                ref.invalidate(superAdminPharmaciesProvider);
              },
              icon: const Icon(Icons.refresh_rounded),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => _quickAction(context, ref, v, t),
              itemBuilder: (ctx) => [
                if (!archived && !suspended)
                  const PopupMenuItem(value: 'suspend', child: Text('Suspend')),
                if (suspended) const PopupMenuItem(value: 'activate', child: Text('Activate')),
                const PopupMenuItem(value: 'force_logout', child: Text('Force logout')),
                const PopupMenuItem(value: 'announce', child: Text('Announcement')),
              ],
            ),
          ],
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PharmacyHeader(
                tenant: t,
                subscription: sub,
                planName: planMap?['name']?.toString(),
                onEdit: () => PharmacyAdminActions.editPharmacy(context, ref, widget.tenantId, t),
              ),
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: TabBar(
                  controller: _tabs,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: const [
                    Tab(text: 'Overview'),
                    Tab(text: 'Staff'),
                    Tab(text: 'Inventory'),
                    Tab(text: 'Sales'),
                    Tab(text: 'Revenue'),
                    Tab(text: 'Devices'),
                    Tab(text: 'Sync'),
                    Tab(text: 'Activity'),
                    Tab(text: 'Subscription'),
                    Tab(text: 'Settings'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _OverviewTab(statsAsync: statsAsync, tenant: t, subscription: sub),
                    _StaffTab(tenantId: widget.tenantId),
                    _StatsOnlyTab(statsAsync: statsAsync, title: 'Inventory', lines: const [
                      ('inventory_lines', 'Medicine / inventory lines'),
                      ('storage_estimate_mb', 'Storage estimate (MB)'),
                    ]),
                    _StatsOnlyTab(statsAsync: statsAsync, title: 'Sales', lines: const [
                      ('sales_30d', 'Sales transactions (30d)'),
                      ('transaction_rows', 'Transaction rows (all time)'),
                    ]),
                    _RevenueTab(statsAsync: statsAsync, subscription: sub, planName: planMap?['name']?.toString()),
                    _DevicesTab(tenantId: widget.tenantId),
                    _SyncTab(statsAsync: statsAsync, tenant: t),
                    _ActivityTab(tenantId: widget.tenantId),
                    _SubscriptionTab(
                      tenantId: widget.tenantId,
                      current: sub,
                      onSaved: () {
                        ref.invalidate(superAdminPharmacyDetailProvider(widget.tenantId));
                        ref.invalidate(superAdminPharmaciesProvider);
                        kpmsSnack(context, 'Subscription updated.');
                      },
                    ),
                    _SettingsTab(tenantId: widget.tenantId, tenant: t),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _quickAction(BuildContext context, WidgetRef ref, String v, Map<String, dynamic> t) async {
    switch (v) {
      case 'suspend':
        await PharmacyAdminActions.suspend(context, ref, widget.tenantId);
      case 'activate':
        await PharmacyAdminActions.reactivate(context, ref, widget.tenantId);
      case 'force_logout':
        await PharmacyAdminActions.forceLogout(context, ref, widget.tenantId);
      case 'announce':
        PharmacyAdminActions.sendAnnouncement(context);
    }
  }
}

class _PharmacyHeader extends StatelessWidget {
  const _PharmacyHeader({
    required this.tenant,
    required this.subscription,
    required this.planName,
    required this.onEdit,
  });

  final Map<String, dynamic> tenant;
  final Map<String, dynamic>? subscription;
  final String? planName;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suspended = tenant['suspended_at'] != null;
    final archived = tenant['deleted_at'] != null;
    return Card(
      margin: const EdgeInsets.only(bottom: PlatformAdminSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(PlatformAdminSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tenant['owner_name']?.toString() ?? '—', style: theme.textTheme.labelLarge?.copyWith(color: theme.hintColor)),
                      Text('ID: ${tenant['id']}', style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'monospace')),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Edit')),
              ],
            ),
            const SizedBox(height: PlatformAdminSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (archived)
                  const PlatformStatusChip(label: 'Archived', tone: PlatformChipTone.danger)
                else if (suspended)
                  const PlatformStatusChip(label: 'Suspended', tone: PlatformChipTone.warning)
                else
                  const PlatformStatusChip(label: 'Active', tone: PlatformChipTone.success),
                PlatformStatusChip(label: planName ?? 'No plan', tone: PlatformChipTone.info),
                PlatformStatusChip(label: subscription?['status']?.toString() ?? '—', tone: PlatformChipTone.neutral),
              ],
            ),
            const SizedBox(height: PlatformAdminSpacing.xs),
            Text('Created ${tenant['created_at'] ?? '—'} · Last activity ${tenant['last_activity_at'] ?? '—'}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ],
        ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.statsAsync, required this.tenant, required this.subscription});

  final AsyncValue<Map<String, dynamic>> statsAsync;
  final Map<String, dynamic> tenant;
  final Map<String, dynamic>? subscription;

  @override
  Widget build(BuildContext context) {
    return statsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (s) {
        return ListView(
          padding: const EdgeInsets.all(PlatformAdminSpacing.md),
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final cols = c.maxWidth >= 900 ? 3 : c.maxWidth >= 560 ? 2 : 1;
                final metrics = [
                  PlatformMetricCard(icon: Icons.point_of_sale_outlined, label: 'Sales (30d)', value: '${s['sales_30d'] ?? 0}'),
                  PlatformMetricCard(icon: Icons.groups_outlined, label: 'Active staff', value: '${s['staff_active'] ?? 0}'),
                  PlatformMetricCard(icon: Icons.medication_outlined, label: 'Medicines', value: '${s['inventory_lines'] ?? 0}'),
                  PlatformMetricCard(icon: Icons.shopping_bag_outlined, label: 'Purchases (30d)', value: '${s['purchases_30d'] ?? 0}'),
                  PlatformMetricCard(icon: Icons.sd_storage_outlined, label: 'Storage est.', value: '~${s['storage_estimate_mb'] ?? 0} MB'),
                  PlatformMetricCard(
                    icon: Icons.event_outlined,
                    label: 'Renewal',
                    value: subscription?['expires_at']?.toString().substring(0, 10) ?? '—',
                    subtitle: subscription?['payment_status']?.toString(),
                  ),
                ];
                return GridView.count(
                  crossAxisCount: cols,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: PlatformAdminSpacing.sm,
                  crossAxisSpacing: PlatformAdminSpacing.sm,
                  childAspectRatio: 1.55,
                  children: metrics,
                );
              },
            ),
            const SizedBox(height: PlatformAdminSpacing.md),
            Card(
              child: ListTile(
                title: const Text('Sync status'),
                subtitle: Text(tenant['suspended_at'] != null ? 'Blocked — tenant suspended' : 'Operational checks pass when tenant is active'),
                trailing: PlatformSyncIndicator(healthy: tenant['suspended_at'] == null),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StaffTab extends ConsumerWidget {
  const _StaffTab({required this.tenantId});

  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(superAdminTenantStaffProvider(tenantId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (rows) {
        if (rows.isEmpty) {
          return const Center(child: Text('No staff profiles for this tenant.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(PlatformAdminSpacing.md),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final r = rows[i];
            return Card(
              child: ListTile(
                title: Text(r['full_name']?.toString() ?? '—'),
                subtitle: Text('${r['role']} · ${r['account_email'] ?? ''}'),
                trailing: Chip(label: Text(r['staff_status']?.toString() ?? '')),
              ),
            );
          },
        );
      },
    );
  }
}

class _StatsOnlyTab extends StatelessWidget {
  const _StatsOnlyTab({required this.statsAsync, required this.title, required this.lines});

  final AsyncValue<Map<String, dynamic>> statsAsync;
  final String title;
  final List<(String key, String label)> lines;

  @override
  Widget build(BuildContext context) {
    return statsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (s) => ListView(
        padding: const EdgeInsets.all(PlatformAdminSpacing.md),
        children: [
          PlatformSectionHeader(title: title, subtitle: 'Aggregates from operator RPC (read-only)'),
          Card(
            child: Column(
              children: [
                for (final line in lines)
                  ListTile(title: Text(line.$2), trailing: Text('${s[line.$1] ?? '—'}')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RevenueTab extends StatelessWidget {
  const _RevenueTab({required this.statsAsync, required this.subscription, required this.planName});

  final AsyncValue<Map<String, dynamic>> statsAsync;
  final Map<String, dynamic>? subscription;
  final String? planName;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(PlatformAdminSpacing.md),
      children: [
        statsAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const SizedBox.shrink(),
          data: (s) => PlatformMetricCard(
            icon: Icons.payments_outlined,
            label: 'Sales volume (30d)',
            value: '${s['sales_30d'] ?? 0} txns',
            subtitle: 'Plan: ${planName ?? '—'}',
          ),
        ),
        const SizedBox(height: PlatformAdminSpacing.sm),
        Card(
          child: Column(
            children: [
              ListTile(title: const Text('Payment status'), trailing: Text(subscription?['payment_status']?.toString() ?? '—')),
              ListTile(title: const Text('Billing interval'), trailing: Text(subscription?['billing_interval']?.toString() ?? '—')),
              ListTile(title: const Text('Grace until'), trailing: Text(subscription?['grace_ends_at']?.toString() ?? '—')),
            ],
          ),
        ),
      ],
    );
  }
}

class _DevicesTab extends ConsumerWidget {
  const _DevicesTab({required this.tenantId});

  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final staff = ref.watch(superAdminTenantStaffProvider(tenantId));
    return staff.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (rows) {
        final active = rows.where((r) => r['staff_status'] == 'active').length;
        return ListView(
          padding: const EdgeInsets.all(PlatformAdminSpacing.md),
          children: [
            PlatformMetricCard(icon: Icons.devices_other_outlined, label: 'Active staff seats', value: '$active'),
            const SizedBox(height: PlatformAdminSpacing.sm),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(PlatformAdminSpacing.md),
                child: Text(
                  'Per-device session telemetry is managed in the pharmacy app. Use Force logout to invalidate all staff sessions for this tenant.',
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SyncTab extends ConsumerWidget {
  const _SyncTab({required this.statsAsync, required this.tenant});

  final AsyncValue<Map<String, dynamic>> statsAsync;
  final Map<String, dynamic> tenant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(superAdminPlatformHealthProvider);
    return ListView(
      padding: const EdgeInsets.all(PlatformAdminSpacing.md),
      children: [
        health.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
          data: (h) => Card(
            child: Column(
              children: [
                ListTile(title: const Text('Platform realtime'), trailing: Text('${h['realtime_ok'] ?? '—'}')),
                ListTile(title: const Text('Push (FCM)'), trailing: Text('${h['push_fcm_ok'] ?? '—'}')),
                ListTile(title: const Text('Failed API (24h)'), trailing: Text('${h['failed_api_window_24h'] ?? '—'}')),
              ],
            ),
          ),
        ),
        const SizedBox(height: PlatformAdminSpacing.sm),
        Card(
          child: ListTile(
            title: const Text('Tenant sync'),
            subtitle: Text(tenant['suspended_at'] != null ? 'Suspended — sync blocked' : 'Cloud sync allowed'),
            trailing: PlatformSyncIndicator(healthy: tenant['suspended_at'] == null),
          ),
        ),
        statsAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
          data: (s) => Card(
            child: ListTile(
              title: const Text('Estimated load'),
              subtitle: Text('${s['transaction_rows'] ?? 0} transaction rows · ${s['inventory_lines'] ?? 0} inventory lines'),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActivityTab extends ConsumerWidget {
  const _ActivityTab({required this.tenantId});

  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(superAdminTenantAuditProvider(tenantId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (rows) {
        if (rows.isEmpty) {
          return const Center(child: Text('No audit events for this tenant yet.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(PlatformAdminSpacing.md),
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final r = rows[i];
            return Card(
              child: ListTile(
                title: Text(r['action']?.toString() ?? '—'),
                subtitle: Text('${r['created_at'] ?? ''}\n${r['metadata'] ?? ''}'),
                isThreeLine: true,
              ),
            );
          },
        );
      },
    );
  }
}

class _SubscriptionTab extends ConsumerWidget {
  const _SubscriptionTab({required this.tenantId, required this.current, required this.onSaved});

  final String tenantId;
  final Map<String, dynamic>? current;
  final VoidCallback onSaved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(superAdminPlansProvider);
    return plans.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) => ListView(
        padding: const EdgeInsets.all(PlatformAdminSpacing.md),
        children: [
          _SubscriptionEditor(tenantId: tenantId, plans: list, current: current, onSaved: onSaved),
        ],
      ),
    );
  }
}

class _SettingsTab extends ConsumerWidget {
  const _SettingsTab({required this.tenantId, required this.tenant});

  final String tenantId;
  final Map<String, dynamic> tenant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suspended = tenant['suspended_at'] != null;
    final archived = tenant['deleted_at'] != null;
    return ListView(
      padding: const EdgeInsets.all(PlatformAdminSpacing.md),
      children: [
        PlatformSectionHeader(title: 'Lifecycle actions', subtitle: 'All actions are audit-logged on the server'),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (!archived && !suspended)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.block_rounded),
                label: const Text('Suspend'),
                onPressed: () => PharmacyAdminActions.suspend(context, ref, tenantId),
              ),
            if (suspended && !archived)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Activate'),
                onPressed: () => PharmacyAdminActions.reactivate(context, ref, tenantId),
              ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.archive_outlined),
              label: const Text('Archive'),
              onPressed: archived ? null : () => PharmacyAdminActions.archiveSoftDelete(context, ref, tenantId),
            ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Force logout'),
              onPressed: archived ? null : () => PharmacyAdminActions.forceLogout(context, ref, tenantId),
            ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.sync_problem_rounded),
              label: const Text('Reset sync'),
              onPressed: archived ? null : () => PharmacyAdminActions.resetSyncCache(context, ref, tenantId),
            ),
          ],
        ),
        const SizedBox(height: PlatformAdminSpacing.lg),
        PlatformSectionHeader(title: 'Danger zone'),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          icon: const Icon(Icons.delete_forever_rounded),
          label: const Text('Permanent delete'),
          onPressed: () => _hardDelete(context, ref),
        ),
      ],
    );
  }

  Future<void> _hardDelete(BuildContext context, WidgetRef ref) async {
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permanent deletion'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Type DELETE to confirm.', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            const SizedBox(height: 12),
            TextField(controller: confirm, decoration: const InputDecoration(border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, confirm.text.trim() == 'DELETE'),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(platformAdminRepositoryProvider).deletePharmacyHard(tenantId);
      if (!context.mounted) return;
      ref.invalidate(superAdminPharmaciesProvider);
      kpmsSnack(context, 'Tenant permanently deleted.');
      context.go(AppRoutes.superAdminPharmacies);
    } catch (e) {
      if (!context.mounted) return;
      kpmsSnack(context, '$e', isError: true);
    }
  }
}

/// Subscription editor (moved from legacy detail card).
class _SubscriptionEditor extends ConsumerStatefulWidget {
  const _SubscriptionEditor({
    required this.tenantId,
    required this.plans,
    required this.current,
    required this.onSaved,
  });

  final String tenantId;
  final List<Map<String, dynamic>> plans;
  final Map<String, dynamic>? current;
  final VoidCallback onSaved;

  @override
  ConsumerState<_SubscriptionEditor> createState() => _SubscriptionEditorState();
}

class _SubscriptionEditorState extends ConsumerState<_SubscriptionEditor> {
  String? _planId;
  DateTime? _expires;
  DateTime? _graceEnds;
  String _billing = 'monthly';
  String _payment = 'current';
  String _status = 'active';

  @override
  void initState() {
    super.initState();
    final c = widget.current;
    _planId = c?['plan_id']?.toString();
    final ex = c?['expires_at'];
    if (ex is String) _expires = DateTime.tryParse(ex)?.toUtc();
    final g = c?['grace_ends_at'];
    if (g is String) _graceEnds = DateTime.tryParse(g)?.toUtc();
    final bi = (c?['billing_interval'] as String?)?.trim();
    if (bi == 'yearly' || bi == 'trial' || bi == 'monthly' || bi == 'lifetime') _billing = bi!;
    _payment = (c?['payment_status'] as String?)?.trim().isNotEmpty == true ? c!['payment_status'] as String : 'current';
    _status = (c?['status'] as String?)?.trim().isNotEmpty == true ? c!['status'] as String : 'active';
  }

  @override
  Widget build(BuildContext context) {
    final activePlans = widget.plans.where((p) => p['is_active'] == true).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(PlatformAdminSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: () {
                if (_planId != null && activePlans.any((p) => p['id']?.toString() == _planId)) return _planId;
                if (activePlans.isEmpty) return null;
                return activePlans.first['id']?.toString();
              }(),
              decoration: const InputDecoration(labelText: 'Plan', border: OutlineInputBorder()),
              items: activePlans
                  .map((p) => DropdownMenuItem(
                        value: p['id']?.toString(),
                        child: Text('${p['name']} (\$${(p['monthly_price_cents'] as num? ?? 0) / 100}/mo)'),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _planId = v),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => setState(() {
                    _billing = 'trial';
                    _expires = DateTime.now().add(const Duration(days: 14));
                    _status = 'active';
                    _payment = 'trialing';
                  }),
                  child: const Text('Trial 14d'),
                ),
                FilledButton.tonal(
                  onPressed: () => setState(() {
                    _billing = 'monthly';
                    _expires = DateTime.now().add(const Duration(days: 30));
                  }),
                  child: const Text('+30d monthly'),
                ),
                FilledButton.tonal(
                  onPressed: () => setState(() {
                    _billing = 'yearly';
                    _expires = DateTime.now().add(const Duration(days: 365));
                  }),
                  child: const Text('+1y yearly'),
                ),
                FilledButton.tonal(
                  onPressed: () => setState(() {
                    _billing = 'lifetime';
                    _expires = null;
                    _status = 'active';
                  }),
                  child: const Text('Lifetime'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ListTile(
              title: Text(_expires == null ? 'No expiry' : 'Expires ${_expires!.toLocal()}'),
              trailing: TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _expires ?? DateTime.now().add(const Duration(days: 30)),
                    firstDate: DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 3650)),
                  );
                  if (picked != null) setState(() => _expires = picked);
                },
                child: const Text('Pick'),
              ),
            ),
            ListTile(
              title: Text(_graceEnds == null ? 'No grace' : 'Grace ${_graceEnds!.toLocal()}'),
              trailing: TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _graceEnds ?? DateTime.now().add(const Duration(days: 7)),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setState(() => _graceEnds = picked);
                },
                child: const Text('Grace'),
              ),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey(_billing),
              initialValue: _billing,
              decoration: const InputDecoration(labelText: 'Billing interval', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                DropdownMenuItem(value: 'yearly', child: Text('Yearly')),
                DropdownMenuItem(value: 'trial', child: Text('Trial')),
                DropdownMenuItem(value: 'lifetime', child: Text('Lifetime')),
              ],
              onChanged: (v) => setState(() => _billing = v ?? 'monthly'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(_payment),
              initialValue: _payment,
              decoration: const InputDecoration(labelText: 'Payment status', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'current', child: Text('current')),
                DropdownMenuItem(value: 'overdue', child: Text('overdue')),
                DropdownMenuItem(value: 'trialing', child: Text('trialing')),
                DropdownMenuItem(value: 'canceled', child: Text('canceled')),
              ],
              onChanged: (v) => setState(() => _payment = v ?? 'current'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: _status,
              decoration: const InputDecoration(labelText: 'Subscription status', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'active', child: Text('active')),
                DropdownMenuItem(value: 'inactive', child: Text('inactive (pause)')),
                DropdownMenuItem(value: 'canceled', child: Text('canceled')),
              ],
              onChanged: (v) => setState(() => _status = v ?? 'active'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _planId == null
                  ? null
                  : () async {
                      await ref.read(platformAdminRepositoryProvider).assignSubscription(
                            tenantId: widget.tenantId,
                            planId: _planId!,
                            expiresAt: _expires,
                            graceEndsAt: _graceEnds,
                            billingInterval: _billing,
                            paymentStatus: _payment,
                            status: _status,
                          );
                      widget.onSaved();
                    },
              child: const Text('Save subscription'),
            ),
          ],
        ),
      ),
    );
  }
}
