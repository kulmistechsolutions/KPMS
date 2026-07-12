import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Consistent spacing for Super Admin surfaces (desktop SaaS).
abstract final class PlatformAdminSpacing {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double section = 28;
}

class PlatformMetricCard extends StatelessWidget {
  const PlatformMetricCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.color,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? AppColors.primary;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(PlatformAdminSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: c, size: 26),
            const SizedBox(height: PlatformAdminSpacing.sm),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
            ],
          ],
        ),
      ),
    );
  }
}

class PlatformStatusChip extends StatelessWidget {
  const PlatformStatusChip({
    super.key,
    required this.label,
    this.tone = PlatformChipTone.neutral,
  });

  final String label;
  final PlatformChipTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      PlatformChipTone.success => (scheme.primaryContainer, scheme.onPrimaryContainer),
      PlatformChipTone.warning => (const Color(0xFFFEF3C7), const Color(0xFF92400E)),
      PlatformChipTone.danger => (scheme.errorContainer, scheme.onErrorContainer),
      PlatformChipTone.info => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      PlatformChipTone.neutral => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      backgroundColor: bg,
      labelStyle: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 11),
    );
  }
}

enum PlatformChipTone { success, warning, danger, info, neutral }

PlatformChipTone operationalStatusTone(String status) {
  switch (status) {
    case 'active':
      return PlatformChipTone.success;
    case 'suspended':
      return PlatformChipTone.warning;
    case 'archived':
      return PlatformChipTone.danger;
    default:
      return PlatformChipTone.neutral;
  }
}

class PlatformSyncIndicator extends StatelessWidget {
  const PlatformSyncIndicator({super.key, required this.healthy});

  final bool healthy;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          healthy ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
          size: 16,
          color: healthy ? Colors.green.shade700 : Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 4),
        Text(
          healthy ? 'Sync OK' : 'Sync risk',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class PlatformSectionHeader extends StatelessWidget {
  const PlatformSectionHeader({super.key, required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlatformAdminSpacing.sm, top: PlatformAdminSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class PlatformSkeletonList extends StatelessWidget {
  const PlatformSkeletonList({super.key, this.count = 6});

  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(height: PlatformAdminSpacing.sm),
      itemBuilder: (_, _) => Card(
        child: SizedBox(
          height: 72,
          child: Padding(
            padding: const EdgeInsets.all(PlatformAdminSpacing.md),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(width: PlatformAdminSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        height: 12,
                        width: 140,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 10,
                        width: 220,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
