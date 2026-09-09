import 'package:flutter/material.dart';

import '../core/models/playing_card.dart';
import '../core/theme.dart';

class PlayingCardWidget extends StatelessWidget {
  final PlayingCard? card;
  final double width;
  final bool enabled;
  final bool highlighted;
  final VoidCallback? onTap;

  const PlayingCardWidget({
    super.key,
    this.card,
    this.width = 60,
    this.enabled = true,
    this.highlighted = false,
    this.onTap,
  });

  double get height => width * 3.5 / 2.5;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(width * 0.12),
          boxShadow: [
            if (highlighted)
              BoxShadow(
                color: AppColors.gold.withValues(alpha: 0.7),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 4,
              offset: const Offset(1, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(width * 0.12),
          child: card != null ? _buildFace() : _buildBack(),
        ),
      ),
    );
  }

  Widget _buildFace() {
    final c = card!;
    final color = (c.suit == Suit.hearts || c.suit == Suit.diamonds)
        ? AppColors.suitRed
        : AppColors.suitBlack;

    return ColorFiltered(
      colorFilter: enabled
          ? const ColorFilter.mode(Colors.transparent, BlendMode.dst)
          : ColorFilter.mode(
              Colors.grey.withValues(alpha: 0.5), BlendMode.saturation),
      child: Container(
        color: AppColors.cardWhite,
        padding: EdgeInsets.all(width * 0.08),
        child: Stack(
          children: [
            // Top-left rank + suit
            Positioned(
              top: 0,
              left: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    c.rank.symbol,
                    style: TextStyle(
                      fontSize: width * 0.22,
                      fontWeight: FontWeight.bold,
                      color: color,
                      height: 1,
                    ),
                  ),
                  Text(
                    c.suit.symbol,
                    style: TextStyle(
                      fontSize: width * 0.18,
                      color: color,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
            // Bottom-right rank + suit (inverted)
            Positioned(
              bottom: 0,
              right: 0,
              child: Transform.rotate(
                angle: 3.14159,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      c.rank.symbol,
                      style: TextStyle(
                        fontSize: width * 0.22,
                        fontWeight: FontWeight.bold,
                        color: color,
                        height: 1,
                      ),
                    ),
                    Text(
                      c.suit.symbol,
                      style: TextStyle(
                        fontSize: width * 0.18,
                        color: color,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Center suit
            Center(
              child: Text(
                c.suit.symbol,
                style: TextStyle(
                  fontSize: width * 0.5,
                  color: color.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBack() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF6D1A36),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.6), width: 2),
        borderRadius: BorderRadius.circular(width * 0.12),
      ),
      child: Center(
        child: Container(
          width: width * 0.6,
          height: height * 0.6,
          decoration: BoxDecoration(
            border: Border.all(
              color: AppColors.gold.withValues(alpha: 0.3),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(width * 0.06),
          ),
          child: Center(
            child: Text(
              '✦',
              style: TextStyle(
                fontSize: width * 0.3,
                color: AppColors.gold.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
