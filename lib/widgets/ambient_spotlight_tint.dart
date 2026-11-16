import 'package:flutter/material.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../services/settings_service.dart';
import 'ambient_artwork_palette.dart';
import 'settings_builder.dart';

/// Theme tint is scoped to the spotlight, so existing scrims and corner
/// artwork naturally blend into the new ambient color without extra blur.
class AmbientSpotlightTint extends StatefulWidget {
  const AmbientSpotlightTint({
    super.key,
    required this.item,
    required this.client,
    required this.allowNetwork,
    required this.localArtworkPathResolver,
    required this.childBuilder,
  });
  final MediaItem? item;
  final MediaServerClient? client;
  final bool allowNetwork;
  final String? Function(String?)? localArtworkPathResolver;
  final Widget Function(BuildContext) childBuilder;

  @override
  State<AmbientSpotlightTint> createState() => _AmbientSpotlightTintState();
}

class _AmbientSpotlightTintState extends State<AmbientSpotlightTint> {
  Color? _accent;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(AmbientSpotlightTint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item?.globalKey != oldWidget.item?.globalKey ||
        widget.client != oldWidget.client) {
      _schedule();
    }
  }

  void _schedule() {
    final generation = ++_generation;
    final media = widget.item;
    final path = media?.heroArtCandidates(containerAspectRatio: 16 / 9).firstOrNull ?? media?.thumbPath;
    if (path == null || path.isEmpty) {
      _accent = null;
      return;
    }
    (() async {
      final color = await AmbientArtworkPalette.resolve(
        path: path,
        client: widget.client,
        allowNetwork: widget.allowNetwork,
        localPath: widget.localArtworkPathResolver?.call(path),
      );
      if (!mounted || generation != _generation) return;
      setState(() => _accent = color);
    })();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingValueBuilder<bool>(
    pref: SettingsService.tvDynamicAmbientBackground,
    builder: (context, enabled, _) {
      final theme = Theme.of(context);
      final base = theme.scaffoldBackgroundColor;
      final accent = enabled ? _accent : null;
      // A localized, multi-stop wash rather than a uniform 28% tint.
      // Keep the artwork widget in the tree: only the paint colors animate.
      final tint = accent == null
          ? base
          : Color.alphaBlend(accent.withValues(alpha: 0.43), base);
      return TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: tint),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOutCubic,
        builder: (context, color, _) {
          final ambient = color ?? base;
          final strength = accent == null ? 0.0 : 1.0;
          return Theme(
            data: theme.copyWith(scaffoldBackgroundColor: ambient),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: base),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      stops: const [0.0, 0.38, 0.78, 1.0],
                      colors: [
                        Color.lerp(base, ambient, 0.94 * strength)!,
                        Color.lerp(base, ambient, 0.65 * strength)!,
                        Color.lerp(base, ambient, 0.27 * strength)!,
                        base,
                      ],
                    ),
                  ),
                ),
                Builder(builder: widget.childBuilder),
              ],
            ),
          );
        },
      );
    },
  );
}
