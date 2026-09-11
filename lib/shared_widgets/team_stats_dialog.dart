import 'package:flutter/material.dart';

import '../core/models/game_state.dart';
import '../core/theme.dart';

class TeamStatsDialog extends StatelessWidget {
  final GameState game;

  const TeamStatsDialog({super.key, required this.game});

  @override
  Widget build(BuildContext context) {
    final statsA = game.teamStats['teamA'] ?? const TeamStats();
    final statsB = game.teamStats['teamB'] ?? const TeamStats();

    return AlertDialog(
      backgroundColor: AppColors.maroonDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.gold, width: 2),
      ),
      title: const Text(
        'Room Stats',
        style: TextStyle(
          color: AppColors.gold,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        textAlign: TextAlign.center,
      ),
      content: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _TeamColumn(
                label: 'Team A',
                color: AppColors.teamA,
                stats: statsA,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _TeamColumn(
                label: 'Team B',
                color: AppColors.teamB,
                stats: statsB,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Close',
            style: TextStyle(color: AppColors.gold),
          ),
        ),
      ],
    );
  }
}

class _TeamColumn extends StatelessWidget {
  final String label;
  final Color color;
  final TeamStats stats;

  const _TeamColumn({
    required this.label,
    required this.color,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.maroonDeep.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          _StatRow(label: 'Wins', value: stats.wins, color: color),
          _StatRow(label: 'Losses', value: stats.losses, color: AppColors.ivory),
          _StatRow(
            label: 'Court',
            value: stats.courtWins,
            color: AppColors.goldLight,
          ),
          _StatRow(
            label: 'Poopy',
            value: stats.poopyWins,
            color: AppColors.silver,
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _StatRow({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.silver,
              fontSize: 13,
            ),
          ),
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
