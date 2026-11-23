import 'dart:async';

import '../media/media_item.dart';
import '../media/media_server_client.dart';

/// One-slot, short-lived season prefetch shared by Discover and TV details.
/// Does not build hidden widgets, fetch episodes or retain a whole catalog.
abstract final class SeriesDetailPrefetch {
  static String? _key;
  static MediaServerClient? _client;
  static Future<List<MediaItem>>? _seasons;
  static DateTime? _started;

  static String _itemKey(MediaItem item) => item.globalKey;

  static void warm(MediaItem item, MediaServerClient client) {
    if (!item.isShow) return;
    final key = _itemKey(item);
    if (_key == key && identical(_client, client) && _seasons != null &&
        _started != null && DateTime.now().difference(_started!) < const Duration(seconds: 25)) {
      return;
    }
    _key = key;
    _client = client;
    _started = DateTime.now();
    // Store an error-safe future: an abandoned focus must not produce an
    // unhandled asynchronous exception.
    _seasons = client.fetchChildren(item.id).catchError((Object _) => <MediaItem>[]);
  }

  static Future<List<MediaItem>>? take(MediaItem item, MediaServerClient client) {
    if (_key != _itemKey(item) || !identical(_client, client) ||
        _started == null || DateTime.now().difference(_started!) >= const Duration(seconds: 25)) {
      return null;
    }
    final result = _seasons;
    _key = null;
    _client = null;
    _seasons = null;
    _started = null;
    return result;
  }
}
