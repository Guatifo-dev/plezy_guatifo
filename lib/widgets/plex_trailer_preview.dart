import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_server_client.dart';
import '../media/primary_trailer.dart';
import '../services/settings_service.dart';
import 'settings_builder.dart';

/// A single logical trailer session shared by the Discover and detail routes.
/// Multiple corner surfaces may attach to it, but extras lookup, the 3-second
/// settle delay and URL resolution happen only once for each selected title.
class PlexTrailerPreview extends StatefulWidget {
  const PlexTrailerPreview({super.key, required this.item, required this.client});

  final MediaItem item;
  final MediaServerClient client;

  /// Stops and releases the shared preview before normal playback takes over.
  static Future<void> stop() async {
    _TrailerPreviewSession.stop();
  }

  @override
  State<PlexTrailerPreview> createState() => _PlexTrailerPreviewState();
}

class _PlexTrailerPreviewState extends State<PlexTrailerPreview> {
  @override
  void initState() {
    super.initState();
    _TrailerPreviewSession.ensure(widget.item, widget.client);
  }

  @override
  void didUpdateWidget(covariant PlexTrailerPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.globalKey != widget.item.globalKey ||
        !identical(oldWidget.client, widget.client)) {
      _TrailerPreviewSession.ensure(widget.item, widget.client);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: _TrailerPreviewSession.url,
      builder: (context, trailerUrl, _) {
        if (trailerUrl == null) return const SizedBox.shrink();
        return SettingValueBuilder<bool>(
          pref: SettingsService.plexTrailerPreviewAudio,
          builder: (context, audioEnabled, _) => AndroidView(
            key: ValueKey('$trailerUrl-$audioEnabled'),
            viewType: 'com.guatifo.plezy/trailer_preview',
            creationParams: <String, Object>{
              'url': trailerUrl,
              'audioEnabled': audioEnabled,
            },
            creationParamsCodec: const StandardMessageCodec(),
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          ),
        );
      },
    );
  }
}

abstract final class _TrailerPreviewSession {
  static const _settleDelay = Duration(seconds: 3);
  static const _controlChannel = MethodChannel('com.guatifo.plezy/trailer_preview_control');
  static final ValueNotifier<String?> url = ValueNotifier<String?>(null);
  static Timer? _timer;
  static String? _itemKey;
  static int _generation = 0;

  static void ensure(MediaItem item, MediaServerClient client) {
    final key = item.globalKey;
    if (_itemKey == key) return;

    _timer?.cancel();
    _timer = null;
    final generation = ++_generation;
    _itemKey = key;
    url.value = null;

    if (!Platform.isAndroid ||
        item.backend != MediaBackend.plex ||
        (!item.isMovie && !item.isShow) ||
        client.backend != MediaBackend.plex) {
      return;
    }

    debugPrint('[TrailerPreview] Scheduled shared session item=' + item.id + ' title=' + item.title);
    _timer = Timer(_settleDelay, () => _load(item, client, generation));
  }

  static Future<void> _load(MediaItem item, MediaServerClient client, int generation) async {
    try {
      debugPrint('[TrailerPreview] Fetching Plex extras for item=' + item.id);
      final extras = await client.fetchExtras(item.id);
      if (!_isCurrent(generation)) return;
      debugPrint('[TrailerPreview] Plex returned ' + extras.length.toString() + ' extras');
      final trailer = primaryTrailer(item, extras);
      if (trailer == null) {
        debugPrint('[TrailerPreview] No trailer identified for item=' + item.id + '; keeping artwork');
        return;
      }

      final target = await client.resolveExternalPlayback(trailer);
      if (!_isCurrent(generation)) return;
      if (target == null || target.url.isEmpty) {
        debugPrint('[TrailerPreview] Trailer playback URL could not be resolved');
        return;
      }
      debugPrint('[TrailerPreview] Resolved shared trailer URL for item=' + item.id);
      url.value = target.url;
    } catch (error) {
      debugPrint('[TrailerPreview] ERROR loading trailer: ' + error.toString());
    }
  }

  static bool _isCurrent(int generation) => generation == _generation;

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _generation++;
    _itemKey = null;
    url.value = null;
    if (Platform.isAndroid) {
      _controlChannel.invokeMethod<void>('stop').catchError((Object error) {
        debugPrint('[TrailerPreview] Could not stop native preview: ' + error.toString());
      });
    }
  }
}
