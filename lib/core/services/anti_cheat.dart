import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ponytail: web-only blur + Android FLAG_SECURE. iOS secure text field trick
// skipped — add when iOS deploy is needed.

mixin AntiCheatMixin<T extends StatefulWidget> on State<T> {
  static const _channel = MethodChannel('com.himachalminds.dehlapakad/secure');
  bool _obscured = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _initWebBlur();
    } else {
      _setAndroidSecure(true);
    }
  }

  @override
  void dispose() {
    if (!kIsWeb) _setAndroidSecure(false);
    super.dispose();
  }

  bool get isObscured => _obscured;

  void _initWebBlur() {
    // Web visibility change handled via WidgetsBindingObserver in the widget
  }

  void _setAndroidSecure(bool secure) {
    try {
      _channel.invokeMethod(secure ? 'setSecure' : 'clearSecure');
    } catch (_) {
      // Platform channel not available (e.g., running on web)
    }
  }

  void onVisibilityChanged(bool hidden) {
    if (mounted) setState(() => _obscured = hidden);
  }
}

class AntiCheatOverlay extends StatelessWidget {
  final bool obscured;
  final Widget child;

  const AntiCheatOverlay({
    super.key,
    required this.obscured,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (obscured)
          Container(
            color: const Color(0xFF2A0A14),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility_off, color: Color(0xFFD4AF37), size: 64),
                  SizedBox(height: 16),
                  Text(
                    'Game Hidden',
                    style: TextStyle(
                      color: Color(0xFFD4AF37),
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Return to the tab to continue playing',
                    style: TextStyle(color: Color(0xFFC0C0C0), fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
