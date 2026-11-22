import 'dart:async';
import 'package:flutter/material.dart';

// ============================================================================
// Floating Capsule Toast Notification (Desktop Overlay Replacement for SnackBar)
// ============================================================================

enum ToastType {
  info,
  success,
  warning,
  error,
}

OverlayEntry? _activeToastEntry;
Timer? _activeToastTimer;

/// Displays a sleek, centered floating capsule toast that auto-dismisses.
void showFloatingToast(
  BuildContext context,
  String message, {
  ToastType type = ToastType.info,
  Duration duration = const Duration(seconds: 3),
}) {
  _dismissActiveToast();

  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  final key = GlobalKey<_FloatingCapsuleToastState>();
  final entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 24,
      right: 24,
      bottom: 28,
      child: SafeArea(
        child: Center(
          child: _FloatingCapsuleToast(
            key: key,
            message: message,
            type: type,
            onDismissRequested: _dismissActiveToast,
          ),
        ),
      ),
    ),
  );

  _activeToastEntry = entry;
  overlay.insert(entry);

  _activeToastTimer = Timer(duration, () async {
    await key.currentState?.animateOut();
    if (_activeToastEntry == entry) {
      _dismissActiveToast();
    }
  });
}

void _dismissActiveToast() {
  _activeToastTimer?.cancel();
  _activeToastTimer = null;
  _activeToastEntry?.remove();
  _activeToastEntry = null;
}

class _FloatingCapsuleToast extends StatefulWidget {
  final String message;
  final ToastType type;
  final VoidCallback onDismissRequested;

  const _FloatingCapsuleToast({
    super.key,
    required this.message,
    required this.type,
    required this.onDismissRequested,
  });

  @override
  State<_FloatingCapsuleToast> createState() => _FloatingCapsuleToastState();
}

class _FloatingCapsuleToastState extends State<_FloatingCapsuleToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.25),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
  }

  Future<void> animateOut() async {
    if (!mounted) return;
    await _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;

    final (IconData icon, Color accent) = switch (widget.type) {
      ToastType.success => (Icons.check_circle_rounded, const Color(0xFF22C55E)),
      ToastType.warning => (Icons.warning_amber_rounded, const Color(0xFFF59E0B)),
      ToastType.error => (Icons.error_outline_rounded, const Color(0xFFEF4444)),
      ToastType.info => (Icons.info_outline_rounded, colorScheme.primary),
    };

    final bgColor = isDark
        ? const Color(0xFF24272E).withValues(alpha: 0.95)
        : const Color(0xFF1F2329).withValues(alpha: 0.92);

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: widget.onDismissRequested,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: accent.withValues(alpha: 0.45),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: accent),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.message,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
