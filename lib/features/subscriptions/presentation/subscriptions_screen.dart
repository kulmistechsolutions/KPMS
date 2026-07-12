import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/kpms_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/kpms_feedback.dart';
import '../../../core/utils/kpms_launch_external_url.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/kpms_page_shell.dart';
import '../../billing/application/billing_providers.dart';
import '../application/tenant_subscription_providers.dart';

/// Tenant subscription overview with WAAFI checkout.
class SubscriptionsScreen extends ConsumerStatefulWidget {
  const SubscriptionsScreen({super.key});

  @override
  ConsumerState<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends ConsumerState<SubscriptionsScreen> {
  String _interval = 'monthly';
  final _couponCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  bool _paying = false;

  @override
  void dispose() {
    _couponCtrl.dispose();
    _mobileCtrl.dispose();
    super.dispose();
  }

  String _normalizeMobile(String raw) {
    var m = raw.replaceAll(RegExp(r'[\s+\-()]'), '');
    if (m.startsWith('00')) m = m.substring(2);
    if (m.startsWith('0') && m.length >= 9) m = '252${m.substring(1)}';
    return m;
  }

  bool _isValidMobile(String m) => m.length >= 10 && RegExp(r'^\d+$').hasMatch(m);

  Future<String?> _promptMobile() async {
    final ctrl = TextEditingController(text: _mobileCtrl.text.trim());
    String? validationError;

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Pay with WAAFI'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Enter the mobile wallet number that will receive the EVC / ZAAD / Sahal payment prompt.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'WAAFI mobile number',
                    hintText: '252611111111',
                    errorText: validationError,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.phone_android_rounded),
                  ),
                  onChanged: (_) {
                    if (validationError != null) {
                      setDialogState(() => validationError = null);
                    }
                  },
                  onSubmitted: (_) {
                    final normalized = _normalizeMobile(ctrl.text.trim());
                    if (_isValidMobile(normalized)) {
                      Navigator.of(ctx).pop(normalized);
                    } else {
                      setDialogState(() {
                        validationError = 'Use full international format, e.g. 252611111111';
                      });
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final normalized = _normalizeMobile(ctrl.text.trim());
                if (!_isValidMobile(normalized)) {
                  setDialogState(() {
                    validationError = 'Use full international format, e.g. 252611111111';
                  });
                  return;
                }
                Navigator.of(ctx).pop(normalized);
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<void> _checkout(String planId, String planName) async {
    if (_paying) return;

    final mobile = await _promptMobile();
    if (mobile == null || mobile.isEmpty) return;

    _mobileCtrl.text = mobile;
    setState(() => _paying = true);
    try {
      final repo = ref.read(billingRepositoryProvider);
      final result = await repo.createCheckout(
        planId: planId,
        billingInterval: _interval,
        couponCode: _couponCtrl.text.trim().isEmpty ? null : _couponCtrl.text.trim(),
        payerMobile: mobile,
      );
      final mode = result['payment_mode']?.toString() ?? 'hpp';
      if (mode == 'api' && result['status']?.toString() == 'paid') {
        if (!mounted) return;
        kpmsSnack(context, '$planName activated — payment approved on your wallet.');
        ref.invalidate(myTenantSubscriptionProvider);
        ref.invalidate(myBillingHistoryProvider);
        return;
      }
      final hppUrl = result['hpp_url']?.toString();
      if (hppUrl == null || hppUrl.isEmpty) {
        throw Exception('No payment URL returned');
      }
      final opened = await kpmsLaunchExternalUrl(hppUrl);
      if (!mounted) return;
      if (opened) {
        kpmsSnack(context, 'Complete payment on WAAFI to activate $planName.');
      } else {
        kpmsSnack(context, 'Open this URL to pay: $hppUrl');
      }
      ref.invalidate(myTenantSubscriptionProvider);
      ref.invalidate(myBillingHistoryProvider);
    } catch (e) {
      if (mounted) kpmsSnack(context, 'Checkout failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = ref.watch(myTenantSubscriptionProvider);
    final catalog = ref.watch(subscriptionCatalogPlansProvider);
    final history = ref.watch(myBillingHistoryProvider);

    final planRow = mine.valueOrNull?['plan_row'] is Map ? Map<String, dynamic>.from(mine.valueOrNull!['plan_row'] as Map) : null;
    final planLabel = planRow?['name']?.toString() ?? mine.valueOrNull?['plan']?.toString() ?? '—';
    final status = mine.valueOrNull?['lifecycle_status']?.toString() ?? mine.valueOrNull?['status']?.toString() ?? '—';
    final expires = mine.valueOrNull?['expires_at']?.toString() ?? '—';
    final payment = mine.valueOrNull?['payment_status']?.toString() ?? '—';

    return KpmsPageShell(
      title: 'Subscription',
      subtitle: 'Plan · WAAFI billing',
      body: ListView(
        padding: KpmsBreakpoints.pageScrollPadding(context),
        children: [
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: mine.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Could not load subscription: $e'),
              data: (row) {
                if (row == null) {
                  return const Text('No subscription row linked to your pharmacy yet.');
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Current plan', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                    Text('$planLabel · $status', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text('Expires: $expires', style: theme.textTheme.bodySmall),
                    Text('Payment: $payment', style: theme.textTheme.bodySmall),
                    if (status == 'pending')
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Payment pending — complete WAAFI checkout to activate.',
                          style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'monthly', label: Text('Monthly')),
              ButtonSegment(value: 'yearly', label: Text('Yearly')),
            ],
            selected: {_interval},
            onSelectionChanged: (s) => setState(() => _interval = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _couponCtrl,
            decoration: const InputDecoration(labelText: 'Coupon code (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _mobileCtrl,
            decoration: const InputDecoration(
              labelText: 'WAAFI mobile wallet (required, e.g. 252611111111)',
              hintText: '25261xxxxxxx',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 20),
          Text('Plans', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          catalog.when(
            loading: () => const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
            error: (e, _) => Text('Plans: $e'),
            data: (plans) {
              if (plans.isEmpty) {
                return Text('No public plans configured.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor));
              }
              return Column(
                children: plans.map((p) {
                  final monthly = (p['monthly_price_cents'] as num?)?.toInt() ?? 0;
                  final yearly = (p['yearly_price_cents'] as num?)?.toInt() ?? 0;
                  final cents = _interval == 'yearly' ? (yearly > 0 ? yearly : monthly * 12) : monthly;
                  final price = cents == 0 ? 'Free' : '\$${(cents / 100).toStringAsFixed(2)}/${_interval == 'yearly' ? 'yr' : 'mo'}';
                  final planId = p['id']?.toString() ?? '';
                  final planName = p['name']?.toString() ?? '';
                  final isCurrent = planRow != null && planRow['id']?.toString() == planId;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      elevation: isCurrent ? 2 : 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(
                          color: isCurrent ? AppColors.primary : theme.dividerColor.withValues(alpha: 0.3),
                          width: isCurrent ? 2 : 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(planName, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                                ),
                                Text(price, style: theme.textTheme.headlineSmall?.copyWith(color: AppColors.tertiary)),
                              ],
                            ),
                            if ((p['description']?.toString() ?? '').isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(p['description']?.toString() ?? '', style: theme.textTheme.bodyMedium),
                            ],
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: isCurrent || _paying || cents <= 0 || planId.isEmpty
                                    ? null
                                    : () => _checkout(planId, planName),
                                child: Text(
                                  _paying
                                      ? 'Starting checkout…'
                                      : isCurrent
                                          ? 'Current plan'
                                          : 'Pay with WAAFI',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 24),
          Text('Payment history', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          history.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('$e'),
            data: (rows) {
              if (rows.isEmpty) {
                return Text('No payments yet.', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
              }
              return Column(
                children: rows.map((r) {
                  final cents = (r['amount_cents'] as num?)?.toInt() ?? 0;
                  return ListTile(
                    title: Text(r['invoice_number']?.toString() ?? r['receipt_number']?.toString() ?? 'Payment'),
                    subtitle: Text('${r['status']} · ${r['method'] ?? 'waafi'}'),
                    trailing: Text('\$${(cents / 100).toStringAsFixed(2)}'),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
