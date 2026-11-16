import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../media/media_server_client.dart';
import '../utils/media_image_helper.dart';

/// Small, bounded, in-memory artwork palette. Failures leave the original
/// background untouched. Never decodes full-resolution art for palette work.
class AmbientArtworkPalette {
  static final Map<String, Color> _cache = <String, Color>{};
  static const int maxEntries = 160;

  static Future<Color?> resolve({
    required String path,
    required MediaServerClient? client,
    required bool allowNetwork,
    String? localPath,
  }) async {
    if (_cache.containsKey(path)) return _cache[path];
    if (!allowNetwork && localPath == null) return null;
    try {
      final ImageProvider provider;
      if (localPath != null && await File(localPath).exists()) {
        provider = ResizeImage(FileImage(File(localPath)), width: 40, height: 40);
      } else {
        if (!allowNetwork) return null;
        final url = MediaImageHelper.getOptimizedImageUrl(
          client: client,
          thumbPath: path,
          maxWidth: 40,
          maxHeight: 40,
          pixelRatio: 1,
          imageType: ImageType.art,
        );
        if (url.isEmpty) return null;
        provider = MediaImageHelper.serverArtworkProvider(
          imageUrl: url, memWidth: 40, memHeight: 40,
        );
      }
      final stream = provider.resolve(const ImageConfiguration());
      final completer = Completer<ui.Image>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (!completer.isCompleted) completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (Object error, StackTrace? trace) {
          if (!completer.isCompleted) completer.completeError(error, trace);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      final image = await completer.future.timeout(const Duration(seconds: 4));
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final bytes = data.buffer.asUint8List();
      final buckets = <int, (double, int)>{};
      for (var i = 0; i + 3 < bytes.length; i += 4) {
        if (bytes[i + 3] < 180) continue;
        final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2];
        final max = [r, g, b].reduce((a, b) => a > b ? a : b);
        final min = [r, g, b].reduce((a, b) => a < b ? a : b);
        if (max < 45 || min > 220 || max - min < 22) continue;
        final key = ((r ~/ 32) << 6) | ((g ~/ 32) << 3) | (b ~/ 32);
        final previous = buckets[key];
        final score = (max - min) / 255.0 + 0.15;
        buckets[key] = ((previous?.$1 ?? 0) + score, (previous?.$2 ?? 0) + 1);
      }
      if (buckets.isEmpty) return null;
      final best = buckets.entries.reduce((a, b) => a.value.$1 > b.value.$1 ? a : b).key;
      final color = Color.fromARGB(255, ((best >> 6) & 7) * 32 + 16,
        ((best >> 3) & 7) * 32 + 16, (best & 7) * 32 + 16);
      if (_cache.length >= maxEntries) _cache.remove(_cache.keys.first);
      _cache[path] = color;
      return color;
    } catch (_) {
      return null;
    }
  }
}
