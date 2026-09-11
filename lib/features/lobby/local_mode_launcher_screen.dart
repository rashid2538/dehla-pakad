import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/playing_card.dart';
import '../../core/models/player.dart';
import '../../core/services/audio_service.dart';
import '../../core/services/local_game_session.dart';
import '../../core/theme.dart';

/// Provider for the shared LocalGameSession — lives for the lifetime of the
/// local game. Disposed when the player quits or returns to the menu.
LocalGameSession? _activeSession;

/// Returns the active local session, if any.
LocalGameSession? get activeLocalSession => _activeSession;

/// Clears the active session reference (called on dispose/quit).
void clearActiveLocalSession() {
  _activeSession?.dispose();
  _activeSession = null;
}

class LocalModeLauncherScreen extends StatefulWidget {
  const LocalModeLauncherScreen({super.key});

  @override
  State<LocalModeLauncherScreen> createState() =>
      _LocalModeLauncherScreenState();
}

class _LocalModeLauncherScreenState extends State<LocalModeLauncherScreen> {
  final _nameController = TextEditingController(text: 'You');
  BotDifficulty _difficulty = BotDifficulty.medium;
  bool _loading = false;
  Map<String, dynamic>? _savedGame;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('local_player_name');
    final diffIdx = prefs.getInt('local_bot_difficulty');
    final saved = prefs.getString(LocalGameSession.savedGameKey);
    if (name != null && mounted) _nameController.text = name;
    if (diffIdx != null && diffIdx < BotDifficulty.values.length && mounted) {
      _difficulty = BotDifficulty.values[diffIdx];
    }
    Map<String, dynamic>? savedGame;
    if (saved != null) {
      try {
        final decoded = jsonDecode(saved);
        if (decoded is Map<String, dynamic>) savedGame = decoded;
      } catch (_) {
        // Corrupt save — ignore it.
      }
    }
    if (mounted) setState(() => _savedGame = savedGame);
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('local_player_name', _nameController.text.trim());
    await prefs.setInt('local_bot_difficulty', _difficulty.index);
  }

  Future<void> _resumeGame() async {
    final save = _savedGame;
    if (save == null || _loading) return;
    final session = LocalGameSession.fromSavedGame(save);
    if (session == null) {
      if (mounted) setState(() => _savedGame = null);
      return;
    }
    _activeSession?.dispose();
    _activeSession = session;
    session.resume();
    if (mounted) context.go('/local/play');
  }

  Future<void> _discardSaved() async {
    setState(() => _savedGame = null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(LocalGameSession.savedGameKey);
  }

  String _savedGameSummary(Map<String, dynamic> json) {
    final game = json['game'] as Map<String, dynamic>?;
    final trick = game?['trickNumber'] as int? ?? 1;
    final trump = game?['trumpSuit'] as String?;
    final turnSeat = game?['currentTurnSeat'] as int?;
    final seats = game?['seats'] as Map<String, dynamic>?;
    var turn = '—';
    if (turnSeat != null && seats != null) {
      final seatInfo = seats['$turnSeat'] as Map<String, dynamic>?;
      turn = seatInfo?['displayName'] as String? ?? 'Seat $turnSeat';
    }
    final trumpText = trump == null
        ? 'No Trump'
        : 'Trump ${Suit.fromLetter(trump).symbol}';
    return 'Trick $trick/13 · $trumpText · $turn to play';
  }

  Future<void> _startGame() async {
    if (_loading) return;
    setState(() => _loading = true);

    try {
      await _savePreferences();
      AudioService.instance.play(GameSound.gameStart);
      HapticService.medium();

      final session = LocalGameSession(
        myUid: 'local_human',
        mySeat: 1, // seat 1 = bottom/you
        playerName: _nameController.text.trim().isNotEmpty
            ? _nameController.text.trim()
            : 'You',
        difficulty: _difficulty,
      );
      _activeSession?.dispose();
      _activeSession = session;
      session.start();

      if (mounted) context.go('/local/play');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _quickPlay() async {
    if (_loading) return;
    setState(() => _loading = true);

    try {
      await _savePreferences();
      AudioService.instance.play(GameSound.gameStart);
      HapticService.medium();

      final session = LocalGameSession(
        myUid: 'local_human',
        mySeat: 1,
        playerName: _nameController.text.trim().isNotEmpty
            ? _nameController.text.trim()
            : 'You',
        difficulty: BotDifficulty.medium,
      );
      _activeSession?.dispose();
      _activeSession = session;
      session.start();

      if (mounted) context.go('/local/play');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.maroon, AppColors.maroonDeep],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: AppColors.gold),
                    onPressed: () => context.go('/'),
                  ),
                ),
                const Spacer(),
                // Icon
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.gold, width: 2),
                    gradient: const RadialGradient(
                      colors: [AppColors.burgundy, AppColors.maroonDark],
                    ),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.smart_toy,
                      color: AppColors.gold,
                      size: 48,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Play vs Bots',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Practice your skills offline',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 40),

                if (_savedGame != null) ...[
                  _ResumeCard(
                    summary: _savedGameSummary(_savedGame!),
                    onResume: _resumeGame,
                    onDiscard: _discardSaved,
                  ),
                  const SizedBox(height: 16),
                ],

                // Name input
                SizedBox(
                  width: double.infinity,
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(
                      color: AppColors.ivory,
                      fontSize: 18,
                    ),
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      labelText: 'Your Name',
                      labelStyle: TextStyle(color: AppColors.silver),
                      hintText: 'Enter your name',
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Difficulty picker
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Bot Difficulty',
                    style: TextStyle(
                      color: AppColors.silver,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final d in BotDifficulty.values) ...[
                      Expanded(
                        child: _DifficultyChip(
                          difficulty: d,
                          selected: _difficulty == d,
                          onTap: () => setState(() => _difficulty = d),
                        ),
                      ),
                      if (d != BotDifficulty.hard) const SizedBox(width: 8),
                    ],
                  ],
                ),
                const SizedBox(height: 40),

                // Quick Play button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _loading ? null : _quickPlay,
                    icon: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.maroonDeep,
                            ),
                          )
                        : const Icon(Icons.play_arrow),
                    label: const Text('Quick Play'),
                  ),
                ),
                const SizedBox(height: 12),

                // Play with settings
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _startGame,
                    icon: const Icon(Icons.settings),
                    label: const Text('Play with Settings'),
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResumeCard extends StatelessWidget {
  final String summary;
  final VoidCallback onResume;
  final VoidCallback onDiscard;

  const _ResumeCard({
    required this.summary,
    required this.onResume,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold, width: 1.5),
        gradient: const LinearGradient(
          colors: [AppColors.burgundy, AppColors.maroonDark],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.gold.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.pause_circle_filled,
                  color: AppColors.gold, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'In-Progress Game',
                  style: TextStyle(
                    color: AppColors.gold,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.silver, size: 18),
                tooltip: 'Discard saved game',
                onPressed: onDiscard,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              summary,
              style: const TextStyle(color: AppColors.ivory, fontSize: 12),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onResume,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Resume'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.maroonDark,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DifficultyChip extends StatelessWidget {
  final BotDifficulty difficulty;
  final bool selected;
  final VoidCallback onTap;

  const _DifficultyChip({
    required this.difficulty,
    required this.selected,
    required this.onTap,
  });

  IconData get _icon => switch (difficulty) {
        BotDifficulty.easy => Icons.sentiment_satisfied,
        BotDifficulty.medium => Icons.psychology,
        BotDifficulty.hard => Icons.local_fire_department,
      };

  String get _label => difficulty.name[0].toUpperCase() +
      difficulty.name.substring(1);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.gold.withValues(alpha: 0.2)
              : AppColors.maroonDark,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.gold : AppColors.burgundy,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _icon,
              color: selected ? AppColors.gold : AppColors.silver,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              _label,
              style: TextStyle(
                color: selected ? AppColors.gold : AppColors.silver,
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
