import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/kpms_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/kpms_platform_admin_shell.dart';
import '../../billing/application/billing_providers.dart';

/// Super Admin subscription & billing command center.
class SuperAdminBillingCenterScreen extends ConsumerStatefulWidget {
  const SuperAdminBillingCenterScreen({super.key});

  @override
  ConsumerState<SuperAdminBillingCenterScreen> createState() => _SuperAdminBillingCenterScreenState();
}

class _SuperAdminBillingCenterScreenState extends ConsumerState<SuperAdminBillingCenterScreen> {
  String? _paymentFilter;

  @override
  Widget build(BuildContext context) {
    final analytics = ref.watch(superAdminBillingAnalyticsProvider);
    final payments = ref.watch(superAdminPaymentsProvider(_paymentFilter));
    final theme = Theme.of(context);

    return KpmsPlatformAdminShell(
      title: 'Billing center',
      subtitle: 'Subscriptions · WAAFI payments · trials',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () {
            ref.invalidate(superAdminBillingAnalyticsProvider);
            ref.invalidate(superAdminPaymentsProvider(_paymentFilter));
          },
        ),
      ],
      body: ListView(
        padding: KpmsBreakpoints.pageScrollPadding(context),
        children: [
          analytics.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('Analytics: $e'),
            data: (a) => _KpiGrid(
              items: [
                _Kpi('MRR', '\$${((a['mrr'] as num?) ?? 0).toStringAsFixed(2)}'),
                _Kpi('ARR', '\$${((a['arr'] as num?) ?? 0).toStringAsFixed(2)}'),
                _Kpi('Active', '${a['active_subscriptions'] ?? 0}'),
                _Kpi('Trials', '${a['trial_accounts'] ?? 0}'),
                _Kpi('Expired', '${a['expired_accounts'] ?? 0}'),
                _Kpi('Pending', '${a['pending_payments'] ?? 0}'),
                _Kpi('Failed (30d)', '${a['failed_payments'] ?? 0}'),
                _Kpi('Suspended', '${a['suspended_pharmacies'] ?? 0}'),
                _Kpi('Month revenue', '\$${((a['monthly_revenue'] as num?) ?? 0).toStringAsFixed(2)}'),
                _Kpi('Success rate', '${a['payment_success_rate'] ?? 100}%'),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Text('Payments', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              const Spacer(),
              DropdownButton<String?>(
                value: _paymentFilter,
                hint: const Text('All statuses'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('All')),
                  DropdownMenuItem(value: 'pending', child: Text('Pending')),
                  DropdownMenuItem(value: 'paid', child: Text('Paid')),
                  DropdownMenuItem(value: 'failed', child: Text('Failed')),
                  DropdownMenuItem(value: 'cancelled', child: Text('Cancelled')),
                  DropdownMenuItem(value: 'refunded', child: Text('Refunded')),
                ],
                onChanged: (v) => setState(() => _paymentFilter = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          payments.when(
            loading: () => const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
            error: (e, _) => Text('$e'),
            data: (page) {
              if (page.rows.isEmpty) {
                return Text('No payments yet.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor));
              }
              return Column(
                children: page.rows.map((p) {
                  final cents = (p['amount_cents'] as num?)?.toInt() ?? 0;
                  final status = p['status']?.toString() ?? '—';
                  return Card(
                    child: ListTile(
                      title: Text(p['tenant_name']?.toString() ?? p['tenant_id']?.toString() ?? '—'),
                      subtitle: Text(
                        '${p['plan_name'] ?? '—'} · ${p['method'] ?? '—'} · ${p['waafi_reference_id'] ?? ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('\$${(cents / 100).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(status, style: TextStyle(fontSize: 12, color: _statusColor(status))),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    return switch (status) {
      'paid' => AppColors.tertiary,
      'pending' => Colors.orange,
      'failed' => Colors.red,
      _ => Colors.grey,
    };
  }
}

class _Kpi {
  const _Kpi(this.label, this.value);
  final String label;
  final String value;
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.items});
  final List<_Kpi> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth > 900 ? 4 : (c.maxWidth > 560 ? 2 : 1);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisExtent: 88,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final k = items[i];
            return GlassCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(k.label, style: Theme.of(context).textTheme.labelSmall),
                  Text(k.value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
