import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_server_client.dart';
import '../media/primary_trailer.dart';

/// Plays the selected Plex trailer in an isolated Android TextureView.
///
/// This deliberately does not create another Plezy MPV player: Android's
/// normal playback plugins own a process-wide native SurfaceView, so a second
/// MPV instance would contend with normal playback. The preview uses its own
/// muted Media3 player and a TextureView embedded in this exact Flutter box.
class PlexTrailerPreview extends StatefulWidget {
  const PlexTrailerPreview({super.key, required this.item, required this.client});

  final MediaItem item;
  final MediaServerClient client;

  @override
  State<PlexTrailerPreview> createState() => _PlexTrailerPreviewState();
}

class _PlexTrailerPreviewState extends State<PlexTrailerPreview> {
  static const _settleDelay = Duration(seconds: 3);
  Timer? _timer;
  String? _url;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _schedulePreview();
  }

  @override
  void didUpdateWidget(covariant PlexTrailerPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.globalKey != widget.item.globalKey ||
        !identical(oldWidget.client, widget.client)) {
      _schedulePreview();
    }
  }

  void _schedulePreview() {
    _timer?.cancel();
    final generation = ++_generation;
    if (_url != null) setState(() => _url = null);

    final item = widget.item;
    if (!Platform.isAndroid ||
        item.backend != MediaBackend.plex ||
        (!item.isMovie && !item.isShow) ||
        widget.client.backend != MediaBackend.plex) {
      return;
    }
    _timer = Timer(_settleDelay, () => _loadTrailer(item, widget.client, generation));
  }

  Future<void> _loadTrailer(MediaItem item, MediaServerClient client, int generation) async {
    try {
      final extras = await client.fetchExtras(item.id);
      if (!_isCurrent(generation)) return;
      final trailer = primaryTrailer(item, extras);
      if (trailer == null) return;

      final target = await client.resolveExternalPlayback(trailer);
      if (!_isCurrent(generation) || target == null || target.url.isEmpty) return;
      setState(() => _url = target.url);
    } catch (error) {
      // A missing/unavailable trailer must never disturb the artwork or home UI.
      debugPrint('Plex trailer preview unavailable: $error');
    }
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  @override
  void dispose() {
    _timer?.cancel();
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null) return const SizedBox.shrink();
    return AndroidView(
      viewType: 'com.guatifo.plezy/trailer_preview',
      creationParams: <String, Object>{'url': url},
      creationParamsCodec: const StandardMessageCodec(),
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    );
  }
}
