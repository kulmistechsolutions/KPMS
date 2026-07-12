import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/widgets/kpms_empty_state.dart';
import '../../../core/widgets/kpms_platform_admin_shell.dart';
import '../application/platform_admin_providers.dart';
import 'widgets/pharmacy_row_action_menu.dart';
import 'widgets/platform_admin_ui.dart';

/// Platform directory: search, filters, rich rows, operator actions.
class SuperAdminPharmaciesScreen extends ConsumerStatefulWidget {
  const SuperAdminPharmaciesScreen({super.key});

  @override
  ConsumerState<SuperAdminPharmaciesScreen> createState() => _SuperAdminPharmaciesScreenState();
}

class _SuperAdminPharmaciesScreenState extends ConsumerState<SuperAdminPharmaciesScreen> {
  final _search = TextEditingController();
  String _status = 'all';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyFilters());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _applyFilters() {
    ref.read(superAdminPharmacyPageProvider.notifier).state = 0;
    ref.read(superAdminPharmacyDirectoryQueryProvider.notifier).state = (_search.text.trim(), _status);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(superAdminPharmaciesPageProvider);
    final pageIndex = ref.watch(superAdminPharmacyPageProvider);
    final width = MediaQuery.sizeOf(context).width;
    final useTable = width >= 1000;

    return KpmsPlatformAdminShell(
      title: 'All pharmacies',
      subtitle: 'Tenant lifecycle · subscriptions · operations',
      contentMaxWidth: 1440,
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: () {
            ref.invalidate(superAdminPharmaciesPageProvider);
            ref.invalidate(superAdminPharmaciesProvider);
          },
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FilterBar(
            search: _search,
            status: _status,
            onStatusChanged: (v) {
              setState(() => _status = v);
              _applyFilters();
            },
            onApply: _applyFilters,
          ),
          const SizedBox(height: PlatformAdminSpacing.sm),
          Expanded(
            child: async.when(
              loading: () => const PlatformSkeletonList(count: 8),
              error: (e, _) => KpmsEmptyState(
                icon: Icons.error_outline_rounded,
                title: 'Could not load directory',
                message: '$e',
              ),
              data: (page) {
                final rows = page.rows;
                if (rows.isEmpty) {
                  return KpmsEmptyState(
                    icon: Icons.storefront_outlined,
                    title: 'No pharmacies',
                    message: 'Adjust filters or wait for new pharmacy registrations.',
                  );
                }
                final totalPages = (page.total / superAdminPharmacyPageSize).ceil().clamp(1, 1 << 20);
                final pager = _DirectoryPager(
                  pageIndex: pageIndex,
                  total: page.total,
                  totalPages: totalPages,
                  onPrev: pageIndex > 0
                      ? () => ref.read(superAdminPharmacyPageProvider.notifier).state = pageIndex - 1
                      : null,
                  onNext: pageIndex + 1 < totalPages
                      ? () => ref.read(superAdminPharmacyPageProvider.notifier).state = pageIndex + 1
                      : null,
                );
                if (useTable) {
                  return Column(
                    children: [
                      pager,
                      Expanded(child: _PharmacyDataTable(rows: rows)),
                    ],
                  );
                }
                return Column(
                  children: [
                    pager,
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.only(bottom: PlatformAdminSpacing.md),
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const SizedBox(height: PlatformAdminSpacing.sm),
                        itemBuilder: (context, i) => _PharmacyCard(row: rows[i]),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.search,
    required this.status,
    required this.onStatusChanged,
    required this.onApply,
  });

  final TextEditingController search;
  final String status;
  final ValueChanged<String> onStatusChanged;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 720;
        final searchField = TextField(
          controller: search,
          decoration: InputDecoration(
            labelText: 'Search name, email, phone',
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: IconButton(
              tooltip: 'Search',
              icon: const Icon(Icons.search_rounded),
              onPressed: onApply,
            ),
          ),
          onSubmitted: (_) => onApply(),
        );
        final statusDD = DropdownButtonFormField<String>(
          key: ValueKey(status),
          initialValue: status,
          decoration: const InputDecoration(labelText: 'Status', border: OutlineInputBorder(), isDense: true),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All')),
            DropdownMenuItem(value: 'active', child: Text('Active')),
            DropdownMenuItem(value: 'suspended', child: Text('Suspended')),
            DropdownMenuItem(value: 'archived', child: Text('Archived')),
          ],
          onChanged: (v) {
            if (v != null) onStatusChanged(v);
          },
        );
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              searchField,
              const SizedBox(height: PlatformAdminSpacing.sm),
              statusDD,
              const SizedBox(height: PlatformAdminSpacing.sm),
              FilledButton.tonalIcon(onPressed: onApply, icon: const Icon(Icons.filter_alt_outlined), label: const Text('Apply')),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: searchField),
            const SizedBox(width: PlatformAdminSpacing.sm),
            SizedBox(width: 200, child: statusDD),
            const SizedBox(width: PlatformAdminSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: FilledButton.tonalIcon(onPressed: onApply, icon: const Icon(Icons.filter_alt_outlined), label: const Text('Apply')),
            ),
          ],
        );
      },
    );
  }
}

class _PharmacyCard extends ConsumerWidget {
  const _PharmacyCard({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final id = row['tenant_id']?.toString() ?? '';
    final status = row['operational_status']?.toString() ?? '';
    final recent = _isRecent(row['last_activity_at']);
    final syncOk = status == 'active' && recent;

    return Card(
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: id.isEmpty ? null : () => context.push(AppRoutes.superAdminPharmacyDetail(id)),
        child: Padding(
          padding: const EdgeInsets.all(PlatformAdminSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(Icons.local_pharmacy_rounded, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: PlatformAdminSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row['pharmacy_name']?.toString() ?? '—',
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          row['owner_email']?.toString() ?? row['owner_name_display']?.toString() ?? '—',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                        ),
                      ],
                    ),
                  ),
                  if (id.isNotEmpty) PharmacyRowActionMenu(tenantId: id, row: row, compact: true),
                ],
              ),
              const SizedBox(height: PlatformAdminSpacing.sm),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  PlatformStatusChip(label: status.isEmpty ? 'unknown' : status, tone: operationalStatusTone(status)),
                  if (row['plan_name'] != null)
                    PlatformStatusChip(label: row['plan_name'].toString(), tone: PlatformChipTone.info),
                  if (row['subscription_status'] != null)
                    PlatformStatusChip(label: row['subscription_status'].toString(), tone: PlatformChipTone.neutral),
                  PlatformSyncIndicator(healthy: syncOk),
                  if (recent)
                    const PlatformStatusChip(label: 'Online', tone: PlatformChipTone.success)
                  else
                    const PlatformStatusChip(label: 'Offline', tone: PlatformChipTone.neutral),
                ],
              ),
              const SizedBox(height: PlatformAdminSpacing.xs),
              Text(
                'Last active: ${_shortDate(row['last_activity_at'])} · Created: ${_shortDate(row['created_at'])}',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PharmacyDataTable extends ConsumerWidget {
  const _PharmacyDataTable({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: PlatformAdminSpacing.xl),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 44,
            dataRowMinHeight: 56,
            dataRowMaxHeight: 72,
            columnSpacing: 20,
            columns: const [
              DataColumn(label: Text('Pharmacy')),
              DataColumn(label: Text('Plan')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Sync')),
              DataColumn(label: Text('Last active')),
              DataColumn(label: Text('Actions')),
            ],
            rows: [
              for (final r in rows)
                DataRow(
                  onSelectChanged: (_) {
                    final id = r['tenant_id']?.toString();
                    if (id != null) context.push(AppRoutes.superAdminPharmacyDetail(id));
                  },
                  cells: [
                    DataCell(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(r['pharmacy_name']?.toString() ?? '—', style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(r['owner_email']?.toString() ?? '—', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                        ],
                      ),
                    ),
                    DataCell(Text(r['plan_name']?.toString() ?? '—')),
                    DataCell(PlatformStatusChip(
                      label: r['operational_status']?.toString() ?? '—',
                      tone: operationalStatusTone(r['operational_status']?.toString() ?? ''),
                    )),
                    DataCell(PlatformSyncIndicator(healthy: _isRecent(r['last_activity_at']) && r['operational_status'] == 'active')),
                    DataCell(Text(_shortDate(r['last_activity_at']))),
                    DataCell(
                      PharmacyRowActionMenu(tenantId: r['tenant_id']?.toString() ?? '', row: r),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _isRecent(dynamic v) {
  if (v == null) return false;
  final dt = DateTime.tryParse(v.toString());
  if (dt == null) return false;
  return DateTime.now().difference(dt.toUtc()).inHours < 48;
}

class _DirectoryPager extends StatelessWidget {
  const _DirectoryPager({
    required this.pageIndex,
    required this.total,
    required this.totalPages,
    required this.onPrev,
    required this.onNext,
  });

  final int pageIndex;
  final int total;
  final int totalPages;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PlatformAdminSpacing.sm),
      child: Row(
        children: [
          Text(
            '$total pharmacies · page ${pageIndex + 1} / $totalPages',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left_rounded)),
          IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right_rounded)),
        ],
      ),
    );
  }
}

String _shortDate(dynamic v) {
  if (v == null) return '—';
  final s = v.toString();
  if (s.length >= 16) return s.substring(0, 16).replaceFirst('T', ' ');
  if (s.length >= 10) return s.substring(0, 10);
  return s;
}
