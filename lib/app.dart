import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/security/kpms_app_lock_gate.dart';
import 'core/supabase/supabase_bootstrap.dart';
import 'core/supabase/supabase_config_required_app.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/kpms_auth_recovery_host.dart';
import 'core/widgets/kpms_staff_session_bootstrap_host.dart';
import 'l10n/app_localizations.dart';
import 'l10n/kpms_locale_fallback_delegates.dart';
import 'providers/app_locale_provider.dart';
import 'core/tenant/pharmacy_tenant_isolation_host.dart';
import 'core/push/kpms_push_messaging.dart';
import 'features/notifications/presentation/kpms_operational_notifications_host.dart';
import 'features/pharmacy_cloud/presentation/pharmacy_workspace_bootstrap_host.dart';
import 'features/pharmacy_cloud/presentation/pharmacy_workspace_realtime_host.dart';
import 'providers/pharmacy_local_workspace.dart';
import 'providers/theme_provider.dart';
import 'routes/app_router.dart';

class KpmsApp extends ConsumerWidget {
  const KpmsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!SupabaseBootstrap.isConfigured || SupabaseBootstrap.clientOrNull == null) {
      return const SupabaseConfigRequiredApp();
    }

    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(appLocaleProvider);

    return MaterialApp.router(
      title: 'KULMIS KPMS',
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: kpmsLocalizationsDelegates,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: router,
      builder: (context, child) {
        return KpmsAppLockGate(
          child: PharmacyTenantIsolationHost(
            child: KpmsStaffSessionBootstrapHost(
              child: PharmacyWorkspaceBootstrapHost(
                child: KpmsAuthRecoveryHost(
                  child: PharmacyWorkspaceRealtimeHost(
                    child: KpmsOperationalNotificationsHost(
                      child: KpmsPushMessagingHost(
                        child: PharmacyWorkspaceAutoSaveHost(child: child ?? const SizedBox.shrink()),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
