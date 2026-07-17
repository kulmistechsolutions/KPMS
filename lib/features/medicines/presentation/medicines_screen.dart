import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/kpms_inventory_permission_provider.dart';
import '../../../core/constants/app_routes.dart';
import '../../../core/navigation/kpms_breakpoints.dart';
import '../../../core/responsive/responsive_helpers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/kpms_empty_state.dart';
import '../../../core/widgets/kpms_page_shell.dart';
import '../../../core/widgets/kpms_skeleton.dart';
import '../../../providers/pharmacy_local_workspace.dart';
import '../../pharmacy_cloud/application/pharmacy_cloud_providers.dart';
import '../application/medicine_catalog_insights_provider.dart';
import '../application/medicine_catalog_stats.dart';
import '../data/medicine_catalog_notifier.dart';
import '../domain/medicine.dart';
import '../domain/medicine_type_style.dart';
import 'widgets/medicine_csv_import_dialog.dart';
import 'widgets/medicine_manage_actions.dart';

/// Medicine catalog — uses shared [medicineCatalogProvider] (swap backend later).
class MedicinesScreen extends ConsumerStatefulWidget {
  const MedicinesScreen({super.key});

  @override
  ConsumerState<MedicinesScreen> createState() => _MedicinesScreenState();
}

class _MedicinesScreenState extends ConsumerState<MedicinesScreen> {
  final _search = TextEditingController();
  Timer? _searchDebounce;
  String _searchCommitted = '';
  String _chip = 'All';
  int _visibleLimit = 25;
  bool _analyticsExpanded = true;

  @override
  void initState() {
    super.initState();
    _searchCommitted = _search.text.trim().toLowerCase();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchTextChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 240), () {
      final next = _search.text.trim().toLowerCase();
      if (!mounted || next == _searchCommitted) return;
      setState(() => _searchCommitted = next);
    });
  }

  void _openDetail(Medicine m) {
    final theme = Theme.of(context);
    final style = MedicineTypeStyle.resolve(m);
    final canManage = ref.read(kpmsCanManageInventoryProvider);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: style.softBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: Icon(style.icon, color: style.accent, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(m.name, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _detailRow(ctx, 'Type', m.typeDisplayName),
              _detailRow(ctx, 'Quantity', '${m.quantity}'),
              _detailRow(ctx, 'Buying', '\$${m.buyingPrice.toStringAsFixed(2)}'),
              _detailRow(ctx, 'Selling', '\$${m.sellingPrice.toStringAsFixed(2)}'),
              _detailRow(ctx, 'Min stock alert', '${m.minimumStockAlert}'),
              if (m.expiryDate != null)
                _detailRow(
                  ctx,
                  'Expiry',
                  '${m.expiryDate!.year}-${m.expiryDate!.month.toString().padLeft(2, '0')}-${m.expiryDate!.day.toString().padLeft(2, '0')}',
                ),
              if (m.batchCode != null) _detailRow(ctx, 'Batch', m.batchCode!),
              if ((m.barcode ?? '').isNotEmpty) _detailRow(ctx, 'Barcode', m.barcode!),
              if (canManage) ...[
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          context.push(MedicineManageActions.editRouteFor(m));
                        },
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Edit'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: theme.colorScheme.onError,
                        ),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          if (!mounted) return;
                          await MedicineManageActions.confirmAndDelete(context, ref, m);
                        },
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: const Text('Delete'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(BuildContext ctx, String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(k, style: Theme.of(ctx).textTheme.labelMedium?.copyWith(color: Theme.of(ctx).hintColor))),
          Expanded(child: Text(v, style: Theme.of(ctx).textTheme.bodyMedium)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = ref.watch(medicineCatalogProvider);
    final q = _searchCommitted;

    var filtered = rows.where((r) {
      if (q.isNotEmpty) {
        final byName = r.name.toLowerCase().contains(q);
        final byBatch = r.batchCode?.toLowerCase().contains(q) ?? false;
        final byBc = (r.barcode ?? '').toLowerCase().contains(q);
        if (!byName && !byBatch && !byBc) return false;
      }
      switch (_chip) {
        case 'Low stock':
          return r.isLowStock;
        case 'Expiring':
          return r.expiryDate != null && r.expiryDate!.difference(DateTime.now()).inDays <= 90;
        default:
          return true;
      }
    }).toList();

    final page = filtered.take(_visibleLimit).toList();
    final hasMore = filtered.length > _visibleLimit;
    final screenW = MediaQuery.sizeOf(context).width;
    final gutter = KpmsBreakpoints.pagePaddingHorizontal(screenW);
    final canManage = ref.watch(kpmsCanManageInventoryProvider);
    final useCompactActions = isMobile(context);
    final bootstrapReady = ref.watch(pharmacyWorkspaceBootstrapReadyProvider);
    final bootstrapAsync = ref.watch(pharmacyWorkspaceBootstrapProvider);
    final showSkeleton = rows.isEmpty && (!bootstrapReady || bootstrapAsync.isLoading);

    return KpmsPageShell(
      title: 'Medicines',
      subtitle: 'Catalog · pricing · batches · expiry',
      actions: [
        if (canManage)
          IconButton(
            tooltip: 'Import CSV',
            onPressed: () => showMedicineCsvImportDialog(context, ref),
            icon: const Icon(Icons.upload_file_outlined),
          ),
        IconButton(
          tooltip: 'Categories',
          onPressed: () => context.push(AppRoutes.medicineCategories),
          icon: const Icon(Icons.category_outlined),
        ),
        IconButton(
          tooltip: 'Barcode scan',
          onPressed: () => context.push(AppRoutes.barcodeScanner),
          icon: const Icon(Icons.document_scanner_outlined),
        ),
      ],
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => context.push(AppRoutes.addMedicine),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add medicine'),
            )
          : null,
      body: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                gutter,
                12,
                gutter,
                0,
              ),
              child: _MedicinesAnalyticsSection(
                expanded: _analyticsExpanded,
                onToggleExpanded: () => setState(() => _analyticsExpanded = !_analyticsExpanded),
                soonDays: ref.watch(medicineCatalogSoonDaysProvider),
                onSoonDaysChanged: (d) => ref.read(medicineCatalogSoonDaysProvider.notifier).state = d,
                stats: ref.watch(medicineCatalogInsightsProvider),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 8),
            sliver: SliverToBoxAdapter(
              child: GlassCard(
                borderRadius: 14,
                padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final inner = constraints.maxWidth;
                    final hint = inner < 300
                        ? 'Search…'
                        : inner < 400
                            ? 'Name, batch, or barcode…'
                            : 'Search name, batch, or barcode…';
                    return TextField(
                      controller: _search,
                      onChanged: (_) => _onSearchTextChanged(),
                      textInputAction: TextInputAction.search,
                      style: theme.textTheme.bodyLarge,
                      decoration: InputDecoration(
                        hintText: hint,
                        hintMaxLines: 2,
                        hintStyle: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        prefixIcon: Icon(Icons.search_rounded, color: theme.hintColor, size: 22),
                        prefixIconConstraints: const BoxConstraints(minWidth: 40, maxWidth: 40, minHeight: 48, maxHeight: 48),
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        alignLabelWithHint: true,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.zero,
                  children: ['All', 'Low stock', 'Expiring']
                      .map(
                        (e) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(e),
                            selected: _chip == e,
                            onSelected: (_) => setState(() {
                              _chip = e;
                              _visibleLimit = 25;
                            }),
                            showCheckmark: false,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
          if (filtered.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: showSkeleton
                  ? const KpmsListSkeleton(rows: 6)
                  : const KpmsEmptyState(
                      title: 'No medicines match',
                      message: 'Adjust search or filters — or add a new medicine.',
                      icon: Icons.medication_rounded,
                    ),
            )
          else ...[
            SliverPadding(
              padding: KpmsBreakpoints.pageScrollPadding(context, bottomExtra: 82),
              sliver: SliverList.separated(
                itemCount: page.length + (hasMore ? 1 : 0),
                separatorBuilder: (context, index) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  if (hasMore && i == page.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Center(
                        child: TextButton(
                          onPressed: () => setState(() => _visibleLimit += 25),
                          child: Text('Load more (${filtered.length - _visibleLimit} remaining)'),
                        ),
                      ),
                    );
                  }
                  final m = page[i];
                  final style = MedicineTypeStyle.resolve(m);
                  final low = m.isLowStock;
                  return Material(
                      color: theme.cardColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: BorderSide(
                          color: low ? Colors.orange.withValues(alpha: 0.65) : theme.dividerColor.withValues(alpha: 0.25),
                          width: low ? 1.5 : 1,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => _openDetail(m),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 220),
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: style.softBg,
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: style.accent.withValues(alpha: 0.12),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: m.imageBytes != null
                                    ? Image.memory(m.imageBytes!, fit: BoxFit.cover)
                                    : Icon(style.icon, color: style.accent, size: 26),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(m.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                                    Text(
                                      '${m.typeDisplayName} · Buy \$${m.buyingPrice.toStringAsFixed(2)} · Sell \$${m.sellingPrice.toStringAsFixed(2)}',
                                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('Qty ${m.quantity}', style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                                  if (m.expiryDate != null)
                                    Text(
                                      'Exp ${m.expiryDate!.year}-${m.expiryDate!.month.toString().padLeft(2, '0')}',
                                      style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                                    ),
                                  if (low)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        'Low stock',
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          color: Colors.orange.shade800,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  if (canManage)
                                    MedicineManageActions(
                                      medicine: m,
                                      compact: useCompactActions,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MedicinesAnalyticsSection extends StatelessWidget {
  const _MedicinesAnalyticsSection({
    required this.expanded,
    required this.onToggleExpanded,
    required this.soonDays,
    required this.onSoonDaysChanged,
    required this.stats,
  });

  final bool expanded;
  final VoidCallback onToggleExpanded;
  final int soonDays;
  final ValueChanged<int> onSoonDaysChanged;
  final MedicineCatalogInsights stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.28)),
        color: scheme.surface.withValues(alpha: theme.brightness == Brightness.dark ? 0.42 : 0.92),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(Icons.insights_outlined, size: 18, color: AppColors.primaryDark.withValues(alpha: 0.9)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Catalog insights',
                        style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0.2),
                      ),
                      Text(
                        expanded ? 'Inventory signals across your catalog' : '${stats.total} SKUs · tap Show for details',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, height: 1.25),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: onToggleExpanded,
                  icon: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                  label: Text(expanded ? 'Hide' : 'Show'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final w = constraints.maxWidth;
                            var cols = 2;
                            if (w >= 960) {
                              cols = 5;
                            } else if (w >= 640) {
                              cols = 3;
                            }
                            const gap = 10.0;
                            final cardW = (w - gap * (cols - 1)) / cols;
                            Widget card(_AnalyticsMetricSpec spec) {
                              return SizedBox(
                                width: cardW,
                                child: _AnalyticsMetricCard(spec: spec, value: spec.valueOf(stats)),
                              );
                            }

                            return Wrap(
                              spacing: gap,
                              runSpacing: gap,
                              children: [
                                card(
                                  _AnalyticsMetricSpec(
                                    title: 'Total medicines',
                                    subtitle: 'All registered medicines',
                                    icon: Icons.medication_outlined,
                                    tone: _MetricTone.neutral,
                                    valueOf: (s) => s.total,
                                  ),
                                ),
                                card(
                                  _AnalyticsMetricSpec(
                                    title: 'In stock',
                                    subtitle: 'Available quantity > 0',
                                    icon: Icons.inventory_2_outlined,
                                    tone: _MetricTone.positive,
                                    valueOf: (s) => s.inStock,
                                  ),
                                ),
                                card(
                                  _AnalyticsMetricSpec(
                                    title: 'Low stock',
                                    subtitle: 'Medicines at or below minimum alert',
                                    icon: Icons.flag_outlined,
                                    tone: _MetricTone.warning,
                                    valueOf: (s) => s.lowStock,
                                  ),
                                ),
                                card(
                                  _AnalyticsMetricSpec(
                                    title: 'Expired',
                                    subtitle: 'Past expiry date',
                                    icon: Icons.event_busy_outlined,
                                    tone: _MetricTone.critical,
                                    valueOf: (s) => s.expired,
                                  ),
                                ),
                                card(
                                  _AnalyticsMetricSpec(
                                    title: 'Coming soon expired',
                                    subtitle: 'Expiring within $soonDays days',
                                    icon: Icons.schedule_outlined,
                                    tone: _MetricTone.watch,
                                    valueOf: (s) => s.expiringSoon,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Icon(Icons.timelapse_outlined, size: 16, color: theme.hintColor),
                            const SizedBox(width: 6),
                            Text(
                              'Soon window',
                              style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: SegmentedButton<int>(
                                  segments: const [
                                    ButtonSegment(value: 30, label: Text('30d')),
                                    ButtonSegment(value: 60, label: Text('60d')),
                                  ],
                                  selected: {soonDays},
                                  onSelectionChanged: (next) {
                                    if (next.isEmpty) return;
                                    onSoonDaysChanged(next.first);
                                  },
                                  showSelectedIcon: false,
                                  style: ButtonStyle(
                                    visualDensity: VisualDensity.compact,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          if (!expanded) const SizedBox(height: 4),
        ],
      ),
    );
  }
}

enum _MetricTone { neutral, positive, warning, critical, watch }

class _AnalyticsMetricSpec {
  const _AnalyticsMetricSpec({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tone,
    required this.valueOf,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final _MetricTone tone;
  final int Function(MedicineCatalogInsights stats) valueOf;
}

class _AnalyticsMetricCard extends StatelessWidget {
  const _AnalyticsMetricCard({required this.spec, required this.value});

  final _AnalyticsMetricSpec spec;
  final int value;

  Color _dotColor(ThemeData theme) {
    switch (spec.tone) {
      case _MetricTone.neutral:
        return AppColors.neutral.withValues(alpha: 0.55);
      case _MetricTone.positive:
        return AppColors.tertiary.withValues(alpha: 0.75);
      case _MetricTone.warning:
        return AppColors.tertiary.withValues(alpha: 0.95);
      case _MetricTone.critical:
        return theme.colorScheme.error.withValues(alpha: 0.85);
      case _MetricTone.watch:
        return AppColors.primary.withValues(alpha: 0.65);
    }
  }

  Color _iconBg(ThemeData theme) {
    final base = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45);
    switch (spec.tone) {
      case _MetricTone.critical:
        return theme.colorScheme.error.withValues(alpha: 0.08);
      case _MetricTone.warning:
      case _MetricTone.watch:
      case _MetricTone.positive:
      case _MetricTone.neutral:
        return base;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.22)),
        color: scheme.surface.withValues(alpha: theme.brightness == Brightness.dark ? 0.35 : 0.98),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: _iconBg(theme),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: Icon(spec.icon, size: 18, color: scheme.onSurface.withValues(alpha: 0.72)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    spec.title,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface.withValues(alpha: 0.78),
                      height: 1.15,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '$value',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.2),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _dotColor(theme),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    spec.subtitle,
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, height: 1.2),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

