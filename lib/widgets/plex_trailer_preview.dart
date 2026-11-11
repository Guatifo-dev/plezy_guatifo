import 'dart:async';

import 'package:flutter/material.dart';

import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_server_client.dart';
import '../media/primary_trailer.dart';
import '../mpv/mpv.dart';

/// Muted Plex trailer preview for the currently selected TV spotlight item.
///
/// The request is deliberately delayed: fast D-pad navigation must not start
/// a stream for every card the user passes. The preview owns a separate mpv
/// instance and is disposed as soon as the spotlight selection changes.
class PlexTrailerPreview extends StatefulWidget {
  const PlexTrailerPreview({super.key, required this.item, required this.client});

  final MediaItem item;
  final MediaServerClient? client;

  @override
  State<PlexTrailerPreview> createState() => _PlexTrailerPreviewState();
}

class _PlexTrailerPreviewState extends State<PlexTrailerPreview> {
  static const _settleDelay = Duration(seconds: 3);

  Timer? _timer;
  Player? _player;
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
    final oldPlayer = _player;
    _player = null;
    if (mounted && oldPlayer != null) setState(() {});
    if (oldPlayer != null) unawaited(_disposePlayer(oldPlayer));

    final item = widget.item;
    final client = widget.client;
    if (item.backend != MediaBackend.plex ||
        (!item.isMovie && !item.isShow) ||
        client == null ||
        client.backend != MediaBackend.plex) {
      return;
    }

    _timer = Timer(_settleDelay, () => _loadAndPlay(item, client, generation));
  }

  Future<void> _loadAndPlay(
    MediaItem item,
    MediaServerClient client,
    int generation,
  ) async {
    Player? player;
    try {
      final extras = await client.fetchExtras(item.id);
      if (!_isCurrent(generation)) return;

      final trailer = primaryTrailer(item, extras);
      if (trailer == null) return;

      final target = await client.resolveExternalPlayback(trailer);
      if (!_isCurrent(generation) || target == null || target.url.isEmpty) return;

      // Plezy's Android TV build uses mpv by default. Keep the preview muted
      // before opening the URL so no audio can leak during initial buffering.
      final previewPlayer = Player(useExoPlayer: false, hardwareDecoding: true);
      player = previewPlayer;
      await previewPlayer.setVolume(0);
      if (!_isCurrent(generation)) {
        await _disposePlayer(previewPlayer);
        return;
      }

      setState(() => _player = previewPlayer);
      await WidgetsBinding.instance.endOfFrame;
      if (!_isCurrent(generation)) {
        await _disposePlayer(previewPlayer);
        return;
      }

      await previewPlayer.open(Media(target.url));
    } catch (_) {
      if (player != null) {
        if (identical(_player, player)) {
          if (mounted) setState(() => _player = null);
        }
        await _disposePlayer(player);
      }
    }
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _disposePlayer(Player player) async {
    try {
      await player.stop();
    } catch (_) {
      // A player may already have been torn down while an async open was in flight.
    }
    try {
      await player.dispose();
    } catch (_) {
      // Disposal is best-effort during rapid focus changes and route teardown.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _generation++;
    final player = _player;
    _player = null;
    if (player != null) unawaited(_disposePlayer(player));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (player == null) return const SizedBox.shrink();
    return Video(player: player, backgroundColor: Colors.transparent);
  }
}
