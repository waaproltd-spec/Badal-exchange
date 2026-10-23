import 'package:flutter/material.dart';

import '../../models/company_balance.dart';
import '../../models/payment_methods.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';

/// How a company's balance status reads and looks.
(String, Color, IconData) companyStatusLook(String status) => switch (status) {
      'available' => ('Available', AppColors.statusCompleted, Icons.check_circle_rounded),
      'low' => ('Low balance', AppColors.statusFailed, Icons.warning_amber_rounded),
      'stale' => ('Not updated', AppColors.statusPending, Icons.schedule_rounded),
      'offline' => ('Offline', AppColors.statusDuplicate, Icons.wifi_off_rounded),
      _ => ('No balance connection', AppColors.statusDuplicate, Icons.link_off_rounded),
    };

class CompanyStatusPill extends StatelessWidget {
  final String status;
  const CompanyStatusPill(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final (label, color, _) = companyStatusLook(status);
    return Container(
      key: Key('company-status-$status'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.13), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

/// The amount to show for a company: its read balance, or why there is none.
String companyAmount(CompanyBalance c) => switch (c.status) {
      'not_connected' => '—',
      'offline' when c.balance == null => 'Unavailable',
      _ => c.balance == null ? 'Unavailable' : '\$${c.balance}',
    };

/// The Limit to show: what the register can still sell, or why it's unknown.
String companyLimit(CompanyBalance c) => switch (c.status) {
      'not_connected' => '—',
      _ when c.balance == null => '—',
      _ => c.limit == null ? 'Not reported' : '\$${c.limit}',
    };

/// Where the balance comes from and how old it is.
String companySource(CompanyBalance c) {
  if (!c.connected) return 'No balance connection · orders handled by agents';
  final at = c.lastSuccessAt;
  return switch (c.status) {
    'offline' => at == null ? 'Cash register · not read yet' : 'Last known · ${formatDateTime(at)}',
    'stale' => 'Last read ${formatDateTime(at!)} · not updated since',
    _ => 'Cash register · ${c.source ?? 'live'} · ${formatDateTime(at!)}',
  };
}

/// "2 withdrawals ($400.00) waiting. Top up at least $50.00." or the
/// low-balance threshold note; null when nothing needs doing.
String? companyWarning(CompanyBalance c) {
  if (c.waitingWithdrawals > 0) {
    final n = c.waitingWithdrawals;
    final need = c.topUpNeeded == null ? '' : ' Top up at least \$${c.topUpNeeded}.';
    return '$n withdrawal${n == 1 ? '' : 's'} (\$${c.waitingAmount}) waiting for a top-up.$need';
  }
  if (c.status == 'low') return 'Below the low-balance level of \$${c.lowThreshold}.';
  if (c.status == 'offline' && c.connected) return 'Could not read the balance${c.lastError == null ? '' : ': ${c.lastError}'}';
  return null;
}

/// One company in the list.
class CompanyCard extends StatelessWidget {
  final CompanyBalance company;
  final VoidCallback onTap;

  const CompanyCard({super.key, required this.company, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = company;
    final low = c.status == 'low';
    final warning = companyWarning(c);
    final (_, color, _) = companyStatusLook(c.status);
    return ConsoleCard(
      key: Key('company-${c.method}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      color: low ? AppColors.statusFailed.withOpacity(0.05) : null,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MethodLogo(method: c.method, width: 72),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.textPrimary)),
                    const SizedBox(height: 2),
                    Text(companySource(c),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(companyAmount(c),
                          key: Key('company-amount-${c.method}'),
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: c.balance == null ? 14 : 18,
                              color: c.balance == null ? AppColors.textFaint : AppColors.textPrimary)),
                    ),
                    if (c.connected && c.balance != null)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Limit ${companyLimit(c)}',
                            key: Key('company-limit-${c.method}'),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 12.5, color: AppColors.textSecondary)),
                      ),
                    const SizedBox(height: 6),
                    CompanyStatusPill(c.status),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
            ],
          ),
          if (warning != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(warning,
                      key: Key('company-warning-${c.method}'),
                      style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
