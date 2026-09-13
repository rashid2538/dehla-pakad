import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/theme.dart';

// Both overlays are stateful on purpose: result screens rebuild on every
// game-state update (hands published, players confirming), and rolling the
// random layout in build() made pieces jump and their animations restart.

/// Poopy defeat: poops splat onto the screen, stick, slide off, and leave
/// smudges that fade. Paints above the content but ignores touches.
class PoopOverlay extends StatefulWidget {
  const PoopOverlay({super.key});

  @override
  State<PoopOverlay> createState() => _PoopOverlayState();
}

class _PoopOverlayState extends State<PoopOverlay> {
  final _poops = () {
    final rng = Random();
    return List.generate(
      18,
      (_) => (
        fx: rng.nextDouble(),
        fy: rng.nextDouble() * 0.6,
        delay: rng.nextInt(1200),
        fs: 28.0 + rng.nextInt(20),
        slideDur: 2500 + rng.nextInt(1500),
      ),
    );
  }();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return IgnorePointer(
      child: SizedBox.expand(
        child: Stack(
          children: [
            // Residue smudges — appear when poop unsticks, fade slowly
            for (final p in _poops)
              Positioned(
                left: p.fx * (size.width - 40) + p.fs * 0.15,
                top: p.fy * size.height + p.fs * 0.2,
                child:
                    Container(
                          width: p.fs * 0.7,
                          height: p.fs * 0.9,
                          decoration: BoxDecoration(
                            color: const Color(0x80654321),
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(p.fs * 0.2),
                              topRight: Radius.circular(p.fs * 0.25),
                              bottomLeft: Radius.circular(p.fs * 0.35),
                              bottomRight: Radius.circular(p.fs * 0.3),
                            ),
                          ),
                        )
                        .animate()
                        .fadeIn(
                          delay: Duration(milliseconds: p.delay + 1500),
                          duration: 200.ms,
                        )
                        .then(delay: 5000.ms)
                        .fadeOut(duration: 3000.ms),
              ),
            // Poops: splat → stick → slide down
            for (final p in _poops)
              Positioned(
                left: p.fx * (size.width - 40),
                top: p.fy * size.height,
                child: Text('\u{1F4A9}', style: TextStyle(fontSize: p.fs))
                    .animate()
                    .scale(
                      begin: const Offset(3, 3),
                      end: const Offset(1, 1),
                      duration: 300.ms,
                      delay: Duration(milliseconds: p.delay),
                      curve: Curves.bounceOut,
                    )
                    .fadeIn(
                      duration: 100.ms,
                      delay: Duration(milliseconds: p.delay),
                    )
                    .then(delay: 1200.ms)
                    .moveY(
                      begin: 0,
                      end: size.height * (1 - p.fy) + 50,
                      duration: Duration(milliseconds: p.slideDur),
                      curve: Curves.easeIn,
                    ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Victory: confetti falls across the screen. Ignores touches.
class ConfettiOverlay extends StatefulWidget {
  const ConfettiOverlay({super.key});

  @override
  State<ConfettiOverlay> createState() => _ConfettiOverlayState();
}

class _ConfettiOverlayState extends State<ConfettiOverlay> {
  final _pieces = () {
    final rng = Random();
    return List.generate(
      30,
      (_) => (
        fx: rng.nextDouble(),
        delay: rng.nextInt(800),
        dur: 1500 + rng.nextInt(1000),
        color: rng.nextInt(5),
        rotAngle: rng.nextDouble() * 6.28,
      ),
    );
  }();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final colors = [
      AppColors.gold,
      AppColors.goldLight,
      AppColors.suitRed,
      AppColors.ivory,
      AppColors.silver,
    ];

    return IgnorePointer(
      child: SizedBox.expand(
        child: Stack(
          children: [
            for (final p in _pieces)
              Positioned(
                left: p.fx * size.width,
                top: -20,
                child:
                    Container(
                          width: 8,
                          height: 12,
                          decoration: BoxDecoration(
                            color: colors[p.color],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        )
                        .animate()
                        .moveY(
                          begin: 0,
                          end: size.height + 40,
                          duration: Duration(milliseconds: p.dur),
                          delay: Duration(milliseconds: p.delay),
                          curve: Curves.easeIn,
                        )
                        .rotate(
                          begin: 0,
                          end: p.rotAngle,
                          duration: Duration(milliseconds: p.dur),
                        )
                        .fadeOut(
                          delay: Duration(milliseconds: p.dur - 300),
                          duration: 300.ms,
                        ),
              ),
          ],
        ),
      ),
    );
  }
}
