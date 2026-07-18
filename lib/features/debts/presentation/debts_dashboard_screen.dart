import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/navigation/kpms_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/kpms_mobile_bottom_nav.dart';
import '../../../core/widgets/kpms_page_shell.dart';
import '../../sales/application/sales_ledger_notifier.dart';
import '../../suppliers/application/suppliers_notifier.dart';
import '../application/debt_customers_notifier.dart';
import '../application/supplier_payments_notifier.dart';
import '../../dashboard/application/dashboard_providers.dart';

/// Debts & credit — kept as two clearly separate ledgers (customers owe us,
/// we owe suppliers) so the two never blend into one undifferentiated list.
class DebtsDashboardScreen extends ConsumerStatefulWidget {
  const DebtsDashboardScreen({super.key});

  @override
  ConsumerState<DebtsDashboardScreen> createState() => _DebtsDashboardScreenState();
}

class _DebtsDashboardScreenState extends ConsumerState<DebtsDashboardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return KpmsPageShell(
      title: 'Debts & credit',
      subtitle: 'Customer AR · supplier AP',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: theme.cardColor,
            child: TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: 'Customers owe us'),
                Tab(text: 'We owe suppliers'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _CustomerDebtsTab(),
                _SupplierDebtsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Customers tab ─────────────────────────────────────────────────────────

class _CustomerDebtsTab extends ConsumerWidget {
  const _CustomerDebtsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final clearance = KpmsMobileBottomNav.scrollClearanceBottom(context);
    final debtSummary = ref.watch(dashboardDebtSummaryProvider);
    ref.watch(salesLedgerProvider);
    final ledger = ref.read(salesLedgerProvider.notifier);
    final customers = ref.watch(debtCustomersProvider);

    final rows = customers.map((c) {
      return (customer: c, balance: ledger.openDebtTotalForCustomer(c.id));
    }).toList()
      ..sort((a, b) {
        final byBalance = b.balance.compareTo(a.balance);
        return byBalance != 0 ? byBalance : a.customer.name.compareTo(b.customer.name);
      });

    final owing = rows.where((r) => r.balance > 0.009).toList();
    final settled = rows.where((r) => r.balance <= 0.009).toList();

    if (customers.isEmpty) {
      return _EmptyState(
        icon: Icons.people_outline_rounded,
        message: 'No debt customers yet. Selling on credit at checkout creates a profile here automatically.',
      );
    }

    return ListView(
      padding: KpmsBreakpoints.pageScrollPadding(context, bottomExtra: clearance + 8),
      children: [
        _TotalCard(
          label: 'Total owed to you',
          value: debtSummary.customerDebtTotal,
          icon: Icons.people_outline_rounded,
        ),
        const SizedBox(height: 20),
        _SectionLabel('OWING (${owing.length})'),
        const SizedBox(height: 8),
        if (owing.isEmpty)
          Text('No open balances.', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))
        else
          ...owing.map((r) => _PersonRow(
                title: r.customer.name,
                subtitle: r.customer.phoneDisplay.isEmpty ? 'No phone' : r.customer.phoneDisplay,
                trailing: '\$${r.balance.toStringAsFixed(2)}',
                emphasize: true,
                onTap: () => context.push(AppRoutes.debtsCustomerProfile(r.customer.id)),
              )),
        if (settled.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('SETTLED (${settled.length})'),
          const SizedBox(height: 8),
          ...settled.map((r) => _PersonRow(
                title: r.customer.name,
                subtitle: r.customer.phoneDisplay.isEmpty ? 'No phone' : r.customer.phoneDisplay,
                trailing: 'Paid up',
                emphasize: false,
                onTap: () => context.push(AppRoutes.debtsCustomerProfile(r.customer.id)),
              )),
        ],
      ],
    );
  }
}

// ─── Suppliers tab ──────────────────────────────────────────────────────────

class _SupplierDebtsTab extends ConsumerWidget {
  const _SupplierDebtsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final clearance = KpmsMobileBottomNav.scrollClearanceBottom(context);
    final debtSummary = ref.watch(dashboardDebtSummaryProvider);
    final suppliers = ref.watch(suppliersProvider);
    final supPay = ref.watch(supplierPaymentsProvider);

    final rows = [...suppliers]
      ..sort((a, b) {
        final byBalance = b.balanceOwed.compareTo(a.balanceOwed);
        return byBalance != 0 ? byBalance : a.name.compareTo(b.name);
      });

    final owing = rows.where((s) => s.balanceOwed > 0.009).toList();
    final settled = rows.where((s) => s.balanceOwed <= 0.009).toList();

    final recentPayments = [...supPay]..sort((a, b) => b.paidAt.compareTo(a.paidAt));

    if (suppliers.isEmpty) {
      return _EmptyState(
        icon: Icons.local_shipping_outlined,
        message: 'No suppliers yet. Add suppliers from the Suppliers screen to track what you owe them.',
      );
    }

    return ListView(
      padding: KpmsBreakpoints.pageScrollPadding(context, bottomExtra: clearance + 8),
      children: [
        _TotalCard(
          label: 'Total you owe',
          value: debtSummary.supplierDebtTotal,
          icon: Icons.local_shipping_outlined,
        ),
        const SizedBox(height: 20),
        _SectionLabel('OWING (${owing.length})'),
        const SizedBox(height: 8),
        if (owing.isEmpty)
          Text('No open balances.', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))
        else
          ...owing.map((s) => _PersonRow(
                title: s.name,
                subtitle: s.phone.isEmpty ? 'No phone' : s.phone,
                trailing: '\$${s.balanceOwed.toStringAsFixed(2)}',
                emphasize: true,
                onTap: () => context.push('${AppRoutes.supplierFinance}/${s.id}'),
              )),
        if (settled.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('SETTLED (${settled.length})'),
          const SizedBox(height: 8),
          ...settled.map((s) => _PersonRow(
                title: s.name,
                subtitle: s.phone.isEmpty ? 'No phone' : s.phone,
                trailing: 'Paid up',
                emphasize: false,
                onTap: () => context.push('${AppRoutes.supplierFinance}/${s.id}'),
              )),
        ],
        if (recentPayments.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('RECENT PAYMENTS'),
          const SizedBox(height: 8),
          ...recentPayments.take(6).map((r) {
            final sup = ref.read(suppliersProvider.notifier).byId(r.supplierId);
            return _PersonRow(
              title: sup?.name ?? 'Unknown supplier',
              subtitle: r.note.isEmpty
                  ? '${r.paidAt.year}-${r.paidAt.month.toString().padLeft(2, '0')}-${r.paidAt.day.toString().padLeft(2, '0')}'
                  : r.note,
              trailing: '\$${r.amount.toStringAsFixed(2)}',
              emphasize: false,
              onTap: () => context.push('${AppRoutes.supplierFinance}/${r.supplierId}'),
            );
          }),
        ],
      ],
    );
  }
}

// ─── Shared pieces ──────────────────────────────────────────────────────────

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.label, required this.value, required this.icon});

  final String label;
  final double value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outlineMuted.withValues(alpha: 0.75)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 22, color: AppColors.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor)),
                const SizedBox(height: 2),
                Text(
                  '\$${value.toStringAsFixed(2)}',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: 0.7,
        color: theme.hintColor,
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.emphasize,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String trailing;
  final bool emphasize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                    ],
                  ),
                ),
                Text(
                  trailing,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: emphasize ? Colors.orange.shade800 : theme.hintColor,
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: theme.hintColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }
}
