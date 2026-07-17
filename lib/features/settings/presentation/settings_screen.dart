import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/audit/pharmacy_audit_hooks.dart';
import '../../../core/auth/permission_providers.dart';
import '../../../core/constants/app_routes.dart';
import '../../../core/settings/kpms_settings_log.dart';
import '../../../core/errors/kpms_user_facing_error.dart';
import '../../../core/navigation/kpms_breakpoints.dart';
import '../../../core/security/kpms_app_lock_controller.dart';
import '../../../core/security/kpms_app_lock_setup.dart';
import '../../../core/utils/kpms_feedback.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/kpms_change_password_dialog.dart';
import '../../../core/widgets/kpms_page_shell.dart';
import '../../../core/widgets/kpms_pharmacy_logo.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/app_locale_provider.dart';
import '../application/pharmacy_settings_providers.dart';
import '../domain/pharmacy_tenant.dart';
import 'widgets/sync_integrity_card.dart';

void _kpmsCloseSheetThenReloadPharmacy(BuildContext sheetContext, BuildContext parentContext) {
  FocusManager.instance.primaryFocus?.unfocus();
  if (sheetContext.mounted) {
    Navigator.pop(sheetContext);
  }
  Future<void>.delayed(const Duration(milliseconds: 520), () async {
    if (!parentContext.mounted) return;
    final container = ProviderScope.containerOf(parentContext, listen: false);
    await container.read(pharmacySessionProvider.notifier).reload();
  });
}

String _regionLabel(AppLocalizations l, String code) {
  switch (code) {
    case 'SO':
      return l.regionSomalia;
    case 'INTL':
      return l.regionGeneric;
    default:
      return l.regionUseDevice;
  }
}

String _dateFormatLabel(AppLocalizations l, String id) {
  switch (id) {
    case 'ddMMyyyy':
      return l.dateFormatDdMmYyyy;
    case 'MMddyyyy':
      return l.dateFormatMmDdYyyy;
    case 'yyyyMMdd':
      return l.dateFormatYyyyMmDd;
    default:
      return l.dateFormatSystem;
  }
}

String _numberFormatLabel(AppLocalizations l, String id) {
  switch (id) {
    case 'western':
      return l.numberFormatWestern;
    case 'arabicIndic':
      return l.numberFormatArabicIndic;
    default:
      return l.numberFormatSystem;
  }
}

String _paperLabel(AppLocalizations l, String id) {
  switch (id) {
    case 'thermal58':
      return l.paperSizeThermal58;
    case 'thermal80':
      return l.paperSizeThermal80;
    case 'a4':
      return l.paperSizeA4;
    default:
      return l.paperSizeDefault;
  }
}

String _printQualityLabel(AppLocalizations l, String id) {
  switch (id) {
    case 'draft':
      return l.printQualityDraft;
    case 'high':
      return l.printQualityHigh;
    default:
      return l.printQualityNormal;
  }
}

Future<void> _persistMerged(
  WidgetRef ref,
  PharmacyTenant tenant,
  Map<String, Object?> patch,
  BuildContext? snackContext,
  AppLocalizations l,
) async {
  final merged = tenant.mergeSettingsJson(patch);
  try {
    await ref.read(pharmacySettingsRepositoryProvider).updateTenant(
          tenantId: tenant.id,
          name: tenant.name,
          address: tenant.address,
          phone: tenant.phone,
          licenseNumber: tenant.licenseNumber,
          ownerName: tenant.ownerName,
          settings: merged,
        );
    await ref.read(pharmacySessionProvider.notifier).reload();
    unawaited(PharmacyAuditHooks.settingsUpdated(
      tenantId: tenant.id,
      nextData: merged,
    ));
  } catch (e) {
    if (snackContext?.mounted == true) kpmsSnackError(snackContext!, e, fallback: l.snackSaveFailed);
  }
}

/// Enterprise settings hub — grouped sections, localized, mobile-first.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static Duration get _restoreTimeout =>
      kReleaseMode ? const Duration(seconds: 40) : const Duration(seconds: 12);
  bool _restoreInFlight = false;
  bool _restoreTimedOut = false;

  @override
  void initState() {
    super.initState();
    KpmsSettingsLog.settingsOpened();
    WidgetsBinding.instance.addPostFrameCallback((_) => _retryTenantRestore());
  }

  Future<void> _retryTenantRestore() async {
    if (_restoreInFlight || !mounted) return;
    _restoreInFlight = true;
    if (mounted) setState(() => _restoreTimedOut = false);

    try {
      await ref.read(pharmacySessionProvider.notifier).reload().timeout(_restoreTimeout);
    } on TimeoutException {
      KpmsSettingsLog.missingTenantUiShown();
      if (mounted) setState(() => _restoreTimedOut = true);
    } finally {
      _restoreInFlight = false;
    }
  }

  Widget _restoringBody(ThemeData theme, AppLocalizations l, {String? subtitle}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              l.settingsRestoringWorkspace,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final sessionAsync = ref.watch(pharmacySessionProvider);
    final permAsync = ref.watch(kpmsPermissionContextProvider);
    final locale = ref.watch(appLocaleProvider);

    return KpmsPageShell(
      title: l.settingsTitle,
      subtitle: l.settingsSubtitle,
      body: sessionAsync.when(
        loading: () => _restoringBody(theme, l, subtitle: l.commonLoading),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline_rounded, size: 48, color: theme.colorScheme.error),
                const SizedBox(height: 12),
                Text(l.settingsLoadError, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(kpmsUserFacingMessage(e), textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _restoreInFlight ? null : _retryTenantRestore,
                  child: Text(l.commonRetry),
                ),
              ],
            ),
          ),
        ),
        data: (session) {
          if (session == null) {
            if (_restoreInFlight && !_restoreTimedOut) {
              return _restoringBody(theme, l, subtitle: l.settingsRetryingProfile);
            }
            if (!_restoreTimedOut && (sessionAsync.isLoading || permAsync.isLoading)) {
              return _restoringBody(theme, l, subtitle: l.settingsRestoringWorkspace);
            }
            KpmsSettingsLog.missingTenantUiShown();
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(l.settingsNoPharmacy, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _restoreInFlight ? null : _retryTenantRestore,
                      child: Text(l.commonRetry),
                    ),
                  ],
                ),
              ),
            );
          }

          KpmsSettingsLog.tenantContextLoaded();

          final tenant = session.tenant;
          final taxPct = tenant.settingsJson['tax_rate_percent'];
          final taxRateStr = taxPct is num ? taxPct.toString() : '5';
          final taxLabel = l.settingsTaxRateCurrent(taxRateStr);
          final footerPreview = tenant.invoiceFooter;
          final qrOn = tenant.showInvoiceQr;
          final barcodeState = qrOn ? l.commonOn : l.commonOff;
          final invoiceSub = footerPreview != null && footerPreview.isNotEmpty
              ? l.settingsInvoicePreviewFooter(
                  footerPreview.length > 40 ? '${footerPreview.substring(0, 40)}…' : footerPreview,
                  barcodeState,
                )
              : l.settingsInvoicePreviewEmpty;

          final phoneLine = tenant.phone?.trim().isNotEmpty == true ? tenant.phone!.trim() : l.commonNotSet;
          final emailLine = tenant.contactEmail?.trim().isNotEmpty == true ? tenant.contactEmail!.trim() : l.commonNotSet;
          final generalContact = l.settingsGeneralContactLine(phoneLine, emailLine);
          final currencyLine = l.settingsGeneralCurrencyLine(tenant.currencyCode, tenant.timezoneId);

          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            child: ListView(
              key: ValueKey(locale.languageCode),
              padding: KpmsBreakpoints.pageScrollPadding(context),
              children: [
                GlassCard(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Icon(Icons.local_pharmacy_rounded, color: theme.colorScheme.primary, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tenant.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(
                              tenant.licenseNumber ?? l.settingsLicenseNotSet,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                            ),
                            if (tenant.address != null && tenant.address!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(tenant.address!, style: theme.textTheme.bodySmall),
                              ),
                            const SizedBox(height: 4),
                            Text(generalContact, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                            Text(currencyLine, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => _openEditPharmacySheet(context, tenant),
                        child: Text(l.settingsHeroEdit),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                _SectionTitle(text: l.settingsSectionGeneral),
                _SettingsCard(
                  children: [
                    ListTile(
                      leading: Icon(Icons.tune_rounded, color: theme.colorScheme.primary),
                      title: Text(l.settingsGeneralOpen),
                      subtitle: Text(l.settingsGeneralSummary, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openEditPharmacySheet(context, tenant),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _SectionTitle(text: l.settingsSectionRegionFormats),
                _SettingsCard(
                  children: [
                    ListTile(
                      leading: Icon(Icons.public_rounded, color: theme.colorScheme.primary),
                      title: Text(l.settingsRegion),
                      subtitle: Text(_regionLabel(l, tenant.regionCode)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openRegionSheet(context, ref, tenant),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.calendar_month_outlined, color: theme.colorScheme.primary),
                      title: Text(l.settingsDateFormat),
                      subtitle: Text(_dateFormatLabel(l, tenant.dateFormatId)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openDateFormatSheet(context, ref, tenant),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.numbers_rounded, color: theme.colorScheme.primary),
                      title: Text(l.settingsNumberFormat),
                      subtitle: Text(_numberFormatLabel(l, tenant.numberFormatId)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openNumberFormatSheet(context, ref, tenant),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _SectionTitle(text: l.settingsSectionPricing),
                _SettingsCard(
                  children: [
                    ListTile(
                      leading: Icon(Icons.percent_rounded, color: theme.colorScheme.primary),
                      title: Text(l.settingsPricingOpen),
                      subtitle: Text(l.settingsPricingSummary),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openPricingSheet(context, tenant),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.receipt_long_outlined, color: theme.colorScheme.primary),
                      title: Text(l.settingsTaxOpen),
                      subtitle: Text('$taxLabel · ${l.settingsTaxSubtitle}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openTaxSheet(context, tenant),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _SectionTitle(text: l.settingsSectionReceipts),
                _SettingsCard(
                  children: [
                    ListTile(
                      leading: Icon(Icons.description_outlined, color: theme.colorScheme.primary),
                      title: Text(l.settingsInvoiceOpen),
                      subtitle: Text(invoiceSub, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openInvoiceTemplateSheet(context, tenant),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.print_outlined, color: theme.colorScheme.primary),
                      title: Text(l.settingsReceiptExtrasOpen),
                      subtitle: Text(l.settingsReceiptExtrasSummary),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openReceiptExtrasSheet(context, tenant),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _SectionTitle(text: l.settingsSectionNotifications),
                _SettingsCard(
                  children: [
                    SwitchListTile(
                      secondary: Icon(Icons.inventory_2_outlined, color: theme.colorScheme.primary),
                      title: Text(l.notificationsLowStock),
                      subtitle: Text(l.notificationsLowStockSubtitle),
                      value: tenant.notifLowStock,
                      onChanged: (v) => _persistMerged(ref, tenant, {'notif_low_stock': v}, context, l),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: Icon(Icons.event_busy_outlined, color: theme.colorScheme.primary),
                      title: Text(l.notificationsExpiry),
                      subtitle: Text(l.notificationsExpirySubtitle),
                      value: tenant.notifExpiry,
                      onChanged: (v) => _persistMerged(ref, tenant, {'notif_expiry': v}, context, l),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: Icon(Icons.account_balance_wallet_outlined, color: theme.colorScheme.primary),
                      title: Text(l.notificationsDebt),
                      subtitle: Text(l.notificationsDebtSubtitle),
                      value: tenant.notifDebt,
                      onChanged: (v) => _persistMerged(ref, tenant, {'notif_debt': v}, context, l),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: Icon(Icons.volume_up_outlined, color: theme.colorScheme.primary),
                      title: Text(l.notificationsSound),
                      value: tenant.notifSound,
                      onChanged: (v) => _persistMerged(ref, tenant, {'notif_sound': v}, context, l),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: Icon(Icons.vibration_rounded, color: theme.colorScheme.primary),
                      title: Text(l.notificationsVibrate),
                      value: tenant.notifVibrate,
                      onChanged: (v) => _persistMerged(ref, tenant, {'notif_vibrate': v}, context, l),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _SectionTitle(text: l.settingsSectionStaff),
                _SettingsCard(
                  children: [
                    ListTile(
                      leading: Icon(Icons.groups_rounded, color: theme.colorScheme.primary),
                      title: Text(l.settingsStaffOpen),
                      subtitle: Text(l.settingsStaffSummary),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        final perm = ref.read(kpmsPermissionContextProvider).valueOrNull;
                        if (perm?.isPharmacyAdminTier != true) {
                          kpmsSnack(context, l.settingsStaffSummary);
                          return;
                        }
                        context.push(AppRoutes.staff);
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.rule_folder_outlined, color: theme.colorScheme.primary),
                      title: Text(l.staffTemplatesTitle),
                      subtitle: Text(l.staffTemplatesSubtitle),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => kpmsSnack(context, l.staffTemplatesSnack),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.security_rounded, color: theme.colorScheme.primary),
                      title: Text(l.staffSecurityTitle),
                      subtitle: Text(l.staffSecuritySubtitle),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => kpmsSnack(context, l.staffSecuritySnack),
                    ),
                  ],
                ),
                _SettingsCard(
                  children: [
                    ListTile(
                      leading: Icon(Icons.lock_outline_rounded, color: theme.colorScheme.primary),
                      title: Text(l.settingsPasswordTitle),
                      subtitle: Text(l.settingsPasswordSubtitle),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showKpmsChangePasswordDialog(context),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.devices_other_rounded, color: theme.colorScheme.primary),
                      title: Text(l.settingsSessionTitle),
                      subtitle: Text(l.settingsSessionSubtitle),
                      onTap: () => kpmsSnack(context, l.settingsSessionSnack),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.pin_outlined, color: theme.colorScheme.primary),
                      title: Text(l.settingsOptionalPinTitle),
                      subtitle: Text(l.settingsOptionalPinSubtitle),
                      trailing: Text(
                        ref.watch(kpmsAppLockProvider.select((s) => s.hasPin))
                            ? l.appLockStatusOn
                            : l.appLockStatusOff,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      onTap: () => showKpmsAppLockManager(context, ref),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _SectionTitle(text: l.settingsSectionAbout),
                _SettingsCard(
                  children: [
                    const SyncIntegrityCard(),
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.info_outline_rounded, color: theme.colorScheme.primary),
                      title: Text(l.settingsAboutOpen),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.push(AppRoutes.settingsAbout),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Center(
                  child: TextButton.icon(
                    onPressed: () => context.push(AppRoutes.subscriptions),
                    icon: const Icon(Icons.subscriptions_outlined),
                    label: Text(l.settingsManageSubscription),
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = theme.colorScheme.surfaceContainerHighest.withValues(alpha: theme.brightness == Brightness.dark ? 0.35 : 0.65);
    return Material(
      color: fill,
      elevation: 0,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

Future<void> _openRegionSheet(BuildContext parentContext, WidgetRef ref, PharmacyTenant tenant) {
  return showModalBottomSheet<void>(
    context: parentContext,
    useRootNavigator: false,
    showDragHandle: true,
    builder: (ctx) => Consumer(
      builder: (context, ref, _) {
        final l = AppLocalizations.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.settingsRegion, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                RadioGroup<String>(
                  groupValue: tenant.regionCode,
                  onChanged: (v) async {
                    if (v == null) return;
                    await _persistMerged(ref, tenant, {'region_code': v}, parentContext, l);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<String>(title: Text(l.regionUseDevice), value: 'device'),
                      RadioListTile<String>(title: Text(l.regionSomalia), value: 'SO'),
                      RadioListTile<String>(title: Text(l.regionGeneric), value: 'INTL'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<void> _openDateFormatSheet(BuildContext parentContext, WidgetRef ref, PharmacyTenant tenant) {
  return showModalBottomSheet<void>(
    context: parentContext,
    useRootNavigator: false,
    showDragHandle: true,
    builder: (ctx) => Consumer(
      builder: (context, ref, _) {
        final l = AppLocalizations.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.settingsDateFormat, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                RadioGroup<String>(
                  groupValue: tenant.dateFormatId,
                  onChanged: (v) async {
                    if (v == null) return;
                    await _persistMerged(ref, tenant, {'date_format': v}, parentContext, l);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<String>(title: Text(_dateFormatLabel(l, 'system')), value: 'system'),
                      RadioListTile<String>(title: Text(_dateFormatLabel(l, 'ddMMyyyy')), value: 'ddMMyyyy'),
                      RadioListTile<String>(title: Text(_dateFormatLabel(l, 'MMddyyyy')), value: 'MMddyyyy'),
                      RadioListTile<String>(title: Text(_dateFormatLabel(l, 'yyyyMMdd')), value: 'yyyyMMdd'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<void> _openNumberFormatSheet(BuildContext parentContext, WidgetRef ref, PharmacyTenant tenant) {
  return showModalBottomSheet<void>(
    context: parentContext,
    useRootNavigator: false,
    showDragHandle: true,
    builder: (ctx) => Consumer(
      builder: (context, ref, _) {
        final l = AppLocalizations.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.settingsNumberFormat, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                RadioGroup<String>(
                  groupValue: tenant.numberFormatId,
                  onChanged: (v) async {
                    if (v == null) return;
                    await _persistMerged(ref, tenant, {'number_format': v}, parentContext, l);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<String>(title: Text(l.numberFormatSystem), value: 'system'),
                      RadioListTile<String>(title: Text(l.numberFormatWestern), value: 'western'),
                      RadioListTile<String>(title: Text(l.numberFormatArabicIndic), value: 'arabicIndic'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<void> _openReceiptExtrasSheet(BuildContext parentContext, PharmacyTenant tenant) {
  return showModalBottomSheet<void>(
    context: parentContext,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ReceiptExtrasSheet(parentContext: parentContext, tenant: tenant),
  );
}

class _ReceiptExtrasSheet extends ConsumerStatefulWidget {
  const _ReceiptExtrasSheet({required this.parentContext, required this.tenant});

  final BuildContext parentContext;
  final PharmacyTenant tenant;

  @override
  ConsumerState<_ReceiptExtrasSheet> createState() => _ReceiptExtrasSheetState();
}

class _ReceiptExtrasSheetState extends ConsumerState<_ReceiptExtrasSheet> {
  late String _paper;
  late String _quality;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _paper = widget.tenant.receiptPaperSize;
    _quality = widget.tenant.receiptPrintQuality;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final l = AppLocalizations.of(context);
    final parent = widget.parentContext;
    try {
      final merged = widget.tenant.mergeSettingsJson({
        'receipt_paper_size': _paper,
        'receipt_print_quality': _quality,
      });
      await ref.read(pharmacySettingsRepositoryProvider).updateTenant(
            tenantId: widget.tenant.id,
            name: widget.tenant.name,
            address: widget.tenant.address,
            phone: widget.tenant.phone,
            licenseNumber: widget.tenant.licenseNumber,
            ownerName: widget.tenant.ownerName,
            settings: merged,
          );
      if (!mounted || !parent.mounted) return;
      _kpmsCloseSheetThenReloadPharmacy(context, parent);
      if (parent.mounted) kpmsSnack(parent, l.snackInvoiceSaved);
    } catch (e) {
      if (mounted) kpmsSnackError(context, e, fallback: l.snackSaveFailed);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.settingsReceiptExtrasOpen, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            Text(l.receiptPaperSize, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in ['default', 'thermal58', 'thermal80', 'a4'])
                  ChoiceChip(
                    label: Text(_paperLabel(l, id)),
                    selected: _paper == id,
                    onSelected: _saving ? null : (_) => setState(() => _paper = id),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(l.receiptPrintQuality, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final id in ['draft', 'normal', 'high'])
                  ChoiceChip(
                    label: Text(_printQualityLabel(l, id)),
                    selected: _quality == id,
                    onSelected: _saving ? null : (_) => setState(() => _quality = id),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.commonSave),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openPricingSheet(BuildContext parentContext, PharmacyTenant tenant) {
  return showModalBottomSheet<void>(
    context: parentContext,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _EditPricingSheet(parentContext: parentContext, tenant: tenant),
  );
}

class _EditPricingSheet extends ConsumerStatefulWidget {
  const _EditPricingSheet({required this.parentContext, required this.tenant});

  final BuildContext parentContext;
  final PharmacyTenant tenant;

  @override
  ConsumerState<_EditPricingSheet> createState() => _EditPricingSheetState();
}

class _EditPricingSheetState extends ConsumerState<_EditPricingSheet> {
  late final TextEditingController _margin;
  late final TextEditingController _decimals;
  late String _discount;
  late bool _taxInclusive;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final t = widget.tenant;
    final m = t.defaultProfitMarginPercent;
    _margin = TextEditingController(text: m == 0 ? '' : m.toString());
    _decimals = TextEditingController(text: '${t.priceDecimalPlaces}');
    _discount = t.discountBehavior;
    _taxInclusive = t.taxInclusiveDisplay;
  }

  @override
  void dispose() {
    _margin.dispose();
    _decimals.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final margin = double.tryParse(_margin.text.trim());
    if (margin != null && (margin < 0 || margin > 99.99)) {
      kpmsSnack(context, l.validationMarginRange, isError: true);
      return;
    }
    final dec = int.tryParse(_decimals.text.trim());
    if (dec == null || dec < 0 || dec > 6) {
      kpmsSnack(context, l.validationDecimalsRange, isError: true);
      return;
    }
    setState(() => _saving = true);
    final parent = widget.parentContext;
    try {
      final patch = <String, Object?>{
        'price_decimal_places': dec,
        'discount_behavior': _discount,
        'tax_inclusive': _taxInclusive,
      };
      if (margin != null) patch['default_profit_margin_percent'] = margin;
      final merged = widget.tenant.mergeSettingsJson(patch);
      await ref.read(pharmacySettingsRepositoryProvider).updateTenant(
            tenantId: widget.tenant.id,
            name: widget.tenant.name,
            address: widget.tenant.address,
            phone: widget.tenant.phone,
            licenseNumber: widget.tenant.licenseNumber,
            ownerName: widget.tenant.ownerName,
            settings: merged,
          );
      if (!mounted || !parent.mounted) return;
      _kpmsCloseSheetThenReloadPharmacy(context, parent);
      if (parent.mounted) kpmsSnack(parent, l.snackPharmacySaved);
    } catch (e) {
      if (mounted) kpmsSnackError(context, e, fallback: l.snackSaveFailed);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.pricingSheetTitle, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            TextField(
              controller: _margin,
              decoration: InputDecoration(labelText: l.pricingProfitMargin, hintText: l.pricingProfitHint, border: const OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _decimals,
              decoration: InputDecoration(labelText: l.pricingDecimalPlaces, border: const OutlineInputBorder()),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _discount,
              decoration: InputDecoration(labelText: l.pricingDiscountBehavior, border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(value: 'line', child: Text(l.pricingDiscountPerLine)),
                DropdownMenuItem(value: 'total', child: Text(l.pricingDiscountOnTotal)),
              ],
              onChanged: _saving ? null : (v) => setState(() => _discount = v ?? 'line'),
            ),
            SwitchListTile(
              title: Text(l.pricingTaxInclusive),
              subtitle: Text(l.pricingTaxInclusiveSubtitle),
              value: _taxInclusive,
              onChanged: _saving ? null : (v) => setState(() => _taxInclusive = v),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.commonSave),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openEditPharmacySheet(BuildContext parentContext, PharmacyTenant tenant) {
  return showModalBottomSheet<void>(
    context: parentContext,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _EditPharmacySheet(parentContext: parentContext, tenant: tenant),
  );
}

class _EditPharmacySheet extends ConsumerStatefulWidget {
  const _EditPharmacySheet({required this.parentContext, required this.tenant});

  final BuildContext parentContext;
  final PharmacyTenant tenant;

  @override
  ConsumerState<_EditPharmacySheet> createState() => _EditPharmacySheetState();
}

class _EditPharmacySheetState extends ConsumerState<_EditPharmacySheet> {
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _license;
  late final TextEditingController _owner;
  late final TextEditingController _currency;
  late final TextEditingController _timezone;
  late final TextEditingController _manualLogoUrl;
  bool _saving = false;
  bool _logoUploading = false;

  @override
  void initState() {
    super.initState();
    final t = widget.tenant;
    _name = TextEditingController(text: t.name);
    _address = TextEditingController(text: t.address ?? '');
    _phone = TextEditingController(text: t.phone ?? '');
    _email = TextEditingController(text: t.contactEmail ?? '');
    _license = TextEditingController(text: t.licenseNumber ?? '');
    _owner = TextEditingController(text: t.ownerName ?? '');
    _currency = TextEditingController(text: t.currencyCode);
    _timezone = TextEditingController(text: t.timezoneId);
    _manualLogoUrl = TextEditingController(text: t.logoUrl ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    _email.dispose();
    _license.dispose();
    _owner.dispose();
    _currency.dispose();
    _timezone.dispose();
    _manualLogoUrl.dispose();
    super.dispose();
  }

  Future<void> _persistTenantWithSettings(Map<String, dynamic> settingsMap) async {
    await ref.read(pharmacySettingsRepositoryProvider).updateTenant(
          tenantId: widget.tenant.id,
          name: _name.text.trim(),
          address: _address.text.trim().isEmpty ? null : _address.text.trim(),
          phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
          licenseNumber: _license.text.trim().isEmpty ? null : _license.text.trim(),
          ownerName: _owner.text.trim().isEmpty ? null : _owner.text.trim(),
          settings: settingsMap,
        );
    await ref.read(pharmacySessionProvider.notifier).reload();
  }

  Future<void> _pickAndUploadLogo(ImageSource source) async {
    final picker = ImagePicker();
    final x = await picker.pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 88,
    );
    if (x == null || !mounted) return;
    setState(() => _logoUploading = true);
    try {
      final bytes = await x.readAsBytes();
      var ext = 'png';
      final path = x.path;
      if (path.contains('.')) {
        ext = path.split('.').last.toLowerCase();
      }
      if (ext == 'jpg') ext = 'jpeg';
      final url = await ref.read(pharmacyLogoRepositoryProvider).uploadLogo(
            tenantId: widget.tenant.id,
            bytes: bytes,
            fileExtension: ext,
          );
      if (!mounted) return;
      final m = Map<String, dynamic>.from(widget.tenant.settingsJson);
      m['logo_url'] = url;
      await _persistTenantWithSettings(m);
      _manualLogoUrl.text = url;
      if (mounted) setState(() {});
      if (widget.parentContext.mounted) kpmsSnackSuccess(widget.parentContext, 'Logo updated');
    } catch (e) {
      if (mounted) kpmsSnackError(context, e);
    } finally {
      if (mounted) setState(() => _logoUploading = false);
    }
  }

  Future<void> _removeLogoCompletely() async {
    setState(() => _logoUploading = true);
    try {
      await ref.read(pharmacyLogoRepositoryProvider).clearTenantLogoObjects(widget.tenant.id);
      final m = Map<String, dynamic>.from(widget.tenant.settingsJson);
      m.remove('logo_url');
      await _persistTenantWithSettings(m);
      _manualLogoUrl.clear();
      if (mounted) setState(() {});
      if (widget.parentContext.mounted) kpmsSnackSuccess(widget.parentContext, 'Logo removed');
    } catch (e) {
      if (mounted) kpmsSnackError(context, e);
    } finally {
      if (mounted) setState(() => _logoUploading = false);
    }
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final n = _name.text.trim();
    if (n.isEmpty) {
      kpmsSnack(context, l.validationPharmacyNameRequired, isError: true);
      return;
    }
    setState(() => _saving = true);
    final parent = widget.parentContext;
    try {
      final emailTrim = _email.text.trim();
      final patch = <String, Object?>{
        'currency_code': _currency.text.trim().isEmpty ? 'USD' : _currency.text.trim().toUpperCase(),
        'timezone_id': _timezone.text.trim().isEmpty ? 'UTC' : _timezone.text.trim(),
      };
      if (emailTrim.isEmpty) {
        patch['contact_email'] = null;
      } else {
        patch['contact_email'] = emailTrim;
      }
      if (_manualLogoUrl.text.trim().isEmpty) {
        patch['logo_url'] = null;
      } else {
        patch['logo_url'] = _manualLogoUrl.text.trim();
      }
      final merged = widget.tenant.mergeSettingsJson(patch);
      await ref.read(pharmacySettingsRepositoryProvider).updateTenant(
            tenantId: widget.tenant.id,
            name: n,
            address: _address.text.trim().isEmpty ? null : _address.text.trim(),
            phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
            licenseNumber: _license.text.trim().isEmpty ? null : _license.text.trim(),
            ownerName: _owner.text.trim().isEmpty ? null : _owner.text.trim(),
            settings: merged,
          );
      if (!mounted || !parent.mounted) return;
      _kpmsCloseSheetThenReloadPharmacy(context, parent);
      if (parent.mounted) kpmsSnack(parent, l.snackPharmacySaved);
    } catch (e) {
      if (mounted) kpmsSnackError(context, e, fallback: l.snackSaveFailed);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.sheetPharmacyProfile, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            TextField(controller: _name, decoration: InputDecoration(labelText: l.fieldPharmacyName, border: const OutlineInputBorder()), textCapitalization: TextCapitalization.words),
            const SizedBox(height: 12),
            TextField(controller: _address, decoration: InputDecoration(labelText: l.fieldAddress, border: const OutlineInputBorder()), maxLines: 2),
            const SizedBox(height: 12),
            TextField(controller: _phone, decoration: InputDecoration(labelText: l.fieldPhone, border: const OutlineInputBorder()), keyboardType: TextInputType.phone),
            const SizedBox(height: 12),
            TextField(controller: _email, decoration: InputDecoration(labelText: l.fieldEmail, border: const OutlineInputBorder()), keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 12),
            TextField(controller: _license, decoration: InputDecoration(labelText: l.fieldLicense, border: const OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: _owner, decoration: InputDecoration(labelText: l.fieldOwner, border: const OutlineInputBorder()), textCapitalization: TextCapitalization.words),
            const SizedBox(height: 12),
            TextField(controller: _currency, decoration: InputDecoration(labelText: l.fieldCurrency, border: const OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: _timezone, decoration: InputDecoration(labelText: l.fieldTimezone, border: const OutlineInputBorder())),
            const SizedBox(height: 16),
            Text(l.fieldLogoUrl, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Center(
              child: KpmsPharmacyLogo(
                imageUrl: _manualLogoUrl.text.trim().isEmpty ? null : _manualLogoUrl.text.trim(),
                maxWidth: 140,
                maxHeight: 88,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_saving || _logoUploading) ? null : () => _pickAndUploadLogo(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined, size: 20),
                    label: const Text('Gallery'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_saving || _logoUploading) ? null : () => _pickAndUploadLogo(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined, size: 20),
                    label: const Text('Camera'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (_saving || _logoUploading) ? null : _removeLogoCompletely,
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                label: const Text('Remove logo'),
              ),
            ),
            if (_logoUploading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 3),
            ],
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('Logo URL (advanced)', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              subtitle: const Text('PNG, JPG, or WEBP upload above · or paste a public HTTPS URL'),
              children: [
                TextField(
                  controller: _manualLogoUrl,
                  decoration: InputDecoration(
                    labelText: 'Logo image URL (optional)',
                    border: const OutlineInputBorder(),
                    hintText: 'https://…',
                  ),
                  keyboardType: TextInputType.url,
                  maxLines: 2,
                ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.commonSave),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openTaxSheet(BuildContext parentContext, PharmacyTenant tenant) {
  return showModalBottomSheet<void>(
    context: parentContext,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _EditTaxSheet(parentContext: parentContext, tenant: tenant),
  );
}

class _EditTaxSheet extends ConsumerStatefulWidget {
  const _EditTaxSheet({required this.parentContext, required this.tenant});

  final BuildContext parentContext;
  final PharmacyTenant tenant;

  @override
  ConsumerState<_EditTaxSheet> createState() => _EditTaxSheetState();
}

class _EditTaxSheetState extends ConsumerState<_EditTaxSheet> {
  late final TextEditingController _taxPct;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final raw = widget.tenant.settingsJson['tax_rate_percent'];
    final initialPct = raw is num ? raw.toDouble() : 5.0;
    final text = initialPct % 1 == 0 ? '${initialPct.toInt()}' : initialPct.toStringAsFixed(2);
    _taxPct = TextEditingController(text: text);
  }

  @override
  void dispose() {
    _taxPct.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final v = double.tryParse(_taxPct.text.trim());
    if (v == null || v < 0 || v > 100) {
      kpmsSnack(context, l.validationTaxRateRange, isError: true);
      return;
    }
    setState(() => _saving = true);
    final parent = widget.parentContext;
    try {
      final merged = widget.tenant.copySettingsJsonWith(taxRatePercent: v);
      await ref.read(pharmacySettingsRepositoryProvider).updateTenant(
            tenantId: widget.tenant.id,
            name: widget.tenant.name,
            address: widget.tenant.address,
            phone: widget.tenant.phone,
            licenseNumber: widget.tenant.licenseNumber,
            ownerName: widget.tenant.ownerName,
            settings: merged,
          );
      if (!mounted || !parent.mounted) return;
      _kpmsCloseSheetThenReloadPharmacy(context, parent);
      if (parent.mounted) kpmsSnack(parent, l.snackTaxUpdated);
    } catch (e) {
      if (mounted) kpmsSnackError(context, e, fallback: l.snackSaveFailed);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.salesTaxTitle, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(l.salesTaxDescription, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
            const SizedBox(height: 16),
            TextField(
              controller: _taxPct,
              decoration: InputDecoration(labelText: l.fieldTaxRate, border: const OutlineInputBorder(), suffixText: '%'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.commonSave),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openInvoiceTemplateSheet(BuildContext parentContext, PharmacyTenant tenant) {
  return showModalBottomSheet<void>(
    context: parentContext,
    useRootNavigator: false,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _EditInvoiceSheet(parentContext: parentContext, tenant: tenant),
  );
}

class _EditInvoiceSheet extends ConsumerStatefulWidget {
  const _EditInvoiceSheet({required this.parentContext, required this.tenant});

  final BuildContext parentContext;
  final PharmacyTenant tenant;

  @override
  ConsumerState<_EditInvoiceSheet> createState() => _EditInvoiceSheetState();
}

class _EditInvoiceSheetState extends ConsumerState<_EditInvoiceSheet> {
  late final TextEditingController _footer;
  late bool _showQr;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _footer = TextEditingController(text: widget.tenant.invoiceFooter ?? '');
    _showQr = widget.tenant.showInvoiceQr;
  }

  @override
  void dispose() {
    _footer.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    setState(() => _saving = true);
    final parent = widget.parentContext;
    try {
      final merged = widget.tenant.copySettingsJsonWith(
        invoiceFooterText: _footer.text.trim(),
        showInvoiceQr: _showQr,
      );
      await ref.read(pharmacySettingsRepositoryProvider).updateTenant(
            tenantId: widget.tenant.id,
            name: widget.tenant.name,
            address: widget.tenant.address,
            phone: widget.tenant.phone,
            licenseNumber: widget.tenant.licenseNumber,
            ownerName: widget.tenant.ownerName,
            settings: merged,
          );
      if (!mounted || !parent.mounted) return;
      _kpmsCloseSheetThenReloadPharmacy(context, parent);
      if (parent.mounted) kpmsSnack(parent, l.snackInvoiceSaved);
    } catch (e) {
      if (mounted) kpmsSnackError(context, e, fallback: l.snackSaveFailed);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.receiptInvoiceTitle, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            TextField(
              controller: _footer,
              decoration: InputDecoration(labelText: l.receiptFooterLabel, hintText: l.receiptFooterHint, border: const OutlineInputBorder()),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: Text(l.receiptShowBarcode),
              subtitle: Text(l.receiptShowBarcodeSubtitle),
              value: _showQr,
              onChanged: _saving ? null : (v) => setState(() => _showQr = v),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.commonSave),
            ),
          ],
        ),
      ),
    );
  }
}
