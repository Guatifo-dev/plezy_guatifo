import 'dart:async';
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
  Timer? _debounce;
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
    _debounce?.cancel();
    final generation = ++_generation;
    final media = widget.item;
    final path = media?.heroArtCandidates().firstOrNull ?? media?.thumbPath;
    if (path == null || path.isEmpty) {
      _accent = null;
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 180), () async {
      final color = await AmbientArtworkPalette.resolve(
        path: path,
        client: widget.client,
        allowNetwork: widget.allowNetwork,
        localPath: widget.localArtworkPathResolver?.call(path),
      );
      if (!mounted || generation != _generation) return;
      setState(() => _accent = color);
    });
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingValueBuilder<bool>(
    pref: SettingsService.tvDynamicAmbientBackground,
    builder: (context, enabled, _) {
      final theme = Theme.of(context);
      final base = theme.scaffoldBackgroundColor;
      final tint = enabled && _accent != null
          ? Color.alphaBlend(_accent!.withValues(alpha: 0.28), base)
          : base;
      return TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: tint),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
        builder: (context, color, _) => Theme(
          data: theme.copyWith(scaffoldBackgroundColor: color ?? base),
          child: Builder(builder: widget.childBuilder),
        ),
      );
    },
  );
}
