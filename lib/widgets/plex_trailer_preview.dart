import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_server_client.dart';
import '../media/primary_trailer.dart';
import '../services/settings_service.dart';
import 'settings_builder.dart';

/// A single logical trailer session shared by the Discover and detail routes.
/// Multiple surfaces may attach to it, but extras lookup, the configurable
/// settle delay and URL resolution happen only once for each selected title.
class PlexTrailerPreview extends StatefulWidget {
  const PlexTrailerPreview({super.key, required this.item, required this.client});

  final MediaItem item;
  final MediaServerClient client;

  /// Stops and releases the shared preview before normal playback takes over.
  static Future<void> stop() async {
    await _TrailerPreviewSession.stop();
  }

  /// True once the currently attached native surface has rendered a frame.
  /// During route handoff the artwork is covered until this becomes true.
  static ValueListenable<bool> get surfaceReady => _TrailerPreviewSession.surfaceReady;

  /// Marks a route handoff before its new Android surface is attached.
  static void prepareForRoute(Object? routeToken) {
    _TrailerPreviewSession.initialize();
    _TrailerPreviewSession.prepareForRoute(routeToken);
  }

  @override
  State<PlexTrailerPreview> createState() => _PlexTrailerPreviewState();
}

class _PlexTrailerPreviewState extends State<PlexTrailerPreview> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _TrailerPreviewSession.initialize();
    _TrailerPreviewSession.attachWidget();
    _TrailerPreviewSession.ensure(widget.item, widget.client);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      // A preview is never allowed to keep playing after Plezy leaves the
      // foreground or the activity is being torn down.
      unawaited(PlexTrailerPreview.stop());
    } else if (state == AppLifecycleState.resumed) {
      // Recreate the preview lazily after returning to the app.
      _TrailerPreviewSession.ensure(widget.item, widget.client);
    }
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _TrailerPreviewSession.detachWidget();
    super.dispose();
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
  static Duration get _settleDelay => Duration(seconds: switch (SettingsService.instance.read(SettingsService.plexTrailerPreviewDelay)) {
    TrailerPreviewDelay.s1 => 1,
    TrailerPreviewDelay.s2 => 2,
    TrailerPreviewDelay.s3 => 3,
    TrailerPreviewDelay.s4 => 4,
    TrailerPreviewDelay.s5 => 5,
    TrailerPreviewDelay.s7 => 7,
    TrailerPreviewDelay.s10 => 10,
    TrailerPreviewDelay.s15 => 15,
  });
  static const _controlChannel = MethodChannel('com.guatifo.plezy/trailer_preview_control');
  static final ValueNotifier<String?> url = ValueNotifier<String?>(null);
  static final ValueNotifier<bool> surfaceReady = ValueNotifier<bool>(true);
  static bool _channelHandlerInstalled = false;
  static Object? _lastPreparedRoute;
  static Timer? _timer;
  static Timer? _orphanStopTimer;
  static int _attachedWidgets = 0;

  static void attachWidget() {
    _orphanStopTimer?.cancel();
    _orphanStopTimer = null;
    _attachedWidgets++;
  }

  static void detachWidget() {
    if (_attachedWidgets > 0) _attachedWidgets--;
    if (_attachedWidgets != 0) return;

    // Route handoffs can briefly dispose the old PlatformView before the new
    // route mounts its replacement. Wait one short handoff window; if no
    // spotlight has claimed the session again, stop native playback entirely.
    _orphanStopTimer?.cancel();
    _orphanStopTimer = Timer(const Duration(milliseconds: 700), () {
      _orphanStopTimer = null;
      if (_attachedWidgets == 0) unawaited(stop());
    });
  }

  static void initialize() {
    if (_channelHandlerInstalled || !Platform.isAndroid) return;
    _channelHandlerInstalled = true;
    _controlChannel.setMethodCallHandler((call) async {
      if (call.method == 'surfaceWaiting') {
        surfaceReady.value = false;
      } else if (call.method == 'surfaceReady') {
        surfaceReady.value = true;
      }
    });
  }

  static void prepareForRoute(Object? routeToken) {
    if (routeToken == null || identical(_lastPreparedRoute, routeToken)) return;
    _lastPreparedRoute = routeToken;
    if (url.value != null) surfaceReady.value = false;
  }
  static String? _itemKey;
  static int _generation = 0;
  static Future<void> _pendingNativeStop = Future<void>.value();

  static void ensure(MediaItem item, MediaServerClient client) {
    final key = item.globalKey;
    if (_itemKey == key) return;

    _timer?.cancel();
    _timer = null;
    if (_itemKey != null && _itemKey != key) {
      // Retire the previous title's paused native player before this session
      // resolves its own URL.
      _pendingNativeStop = _stopNative();
    }
    final generation = ++_generation;
    _itemKey = key;
    _lastPreparedRoute = null;
    surfaceReady.value = true;
    url.value = null;

    if (!Platform.isAndroid ||
        item.backend != MediaBackend.plex ||
        (!item.isMovie && !item.isShow) ||
        client.backend != MediaBackend.plex) {
      return;
    }

    debugPrint('[TrailerPreview] Scheduled shared session item=' + item.id + ' title=' + (item.title ?? ''));
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
      await _pendingNativeStop;
      if (!_isCurrent(generation)) return;
      debugPrint('[TrailerPreview] Resolved shared trailer URL for item=' + item.id);
      surfaceReady.value = false;
      url.value = target.url;
    } catch (error) {
      debugPrint('[TrailerPreview] ERROR loading trailer: ' + error.toString());
    }
  }

  static bool _isCurrent(int generation) => generation == _generation;

  static Future<void> stop() async {
    _orphanStopTimer?.cancel();
    _orphanStopTimer = null;
    _timer?.cancel();
    _timer = null;
    _generation++;
    _itemKey = null;
    _lastPreparedRoute = null;
    surfaceReady.value = true;
    url.value = null;
    await _stopNative();
  }

  static Future<void> _stopNative() async {
    if (!Platform.isAndroid) return;
    try {
      await _controlChannel.invokeMethod<void>('stop');
    } catch (error) {
      debugPrint('[TrailerPreview] Could not stop native preview: ' + error.toString());
    }
  }
}
