import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_stream.dart';
import '../media/media_server_client.dart';
import '../media/media_source_info.dart';
import '../media/ids.dart';
import '../providers/account_preferences_controller.dart';
import '../services/playback_track_preview.dart';
import '../services/settings_service.dart';
import '../utils/media_quality_labels.dart';
import '../utils/provider_extensions.dart';

/// Read-only format badges for the selected movie or individual episode.
/// Never fetches metadata for every poster in a grid.
class SelectedMediaFormatBadges extends StatefulWidget {
  const SelectedMediaFormatBadges({super.key, required this.item});
  final MediaItem? item;

  @override
  State<SelectedMediaFormatBadges> createState() => _SelectedMediaFormatBadgesState();
}

class _SelectedMediaFormatBadgesState extends State<SelectedMediaFormatBadges> {
  MediaItem? _details;
  MediaSourceInfo? _source;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SelectedMediaFormatBadges oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.globalKey != widget.item?.globalKey) _load();
  }

  void _load() {
    final item = widget.item;
    final generation = ++_generation;
    _details = null;
    _source = null;
    if (item == null || (item.kind != MediaKind.movie && item.kind != MediaKind.episode)) return;
    Future<void>(() async {
      try {
        final client = context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId));
        if (client == null) return;
        final fetched = await client.fetchItem(item.id);
        if (!mounted || generation != _generation || fetched == null) return;
        final detailed = fetched.copyWith(
          serverId: item.serverId ?? fetched.serverId,
          serverName: item.serverName ?? fetched.serverName,
        );
        final source = await client.fetchCachedMediaSourceInfo(detailed.id);
        if (!mounted || generation != _generation) return;
        setState(() { _details = detailed; _source = source; });
      } catch (_) {
        // Missing metadata must never interrupt browsing.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!SettingsService.instance.read(SettingsService.showHeroFormatBadges)) {
      return const SizedBox.shrink();
    }
    final item = _details;
    if (item == null) return const SizedBox.shrink();
    final versionIndex = _source?.mediaIndex ?? 0;
    final videoLabels = buildMediaVideoLabels(item, versionIndex: versionIndex);
    final is4K = videoLabels.any((v) => RegExp(r'^(4K|2160p)$', caseSensitive: false).hasMatch(v.trim()));
    final fullHd = videoLabels.any((v) => RegExp(r'1080p|Full HD', caseSensitive: false).hasMatch(v));
    final versions = item.mediaVersions;
    final streams = <MediaStream>[];
    if (versions != null && versionIndex >= 0 && versionIndex < versions.length) {
      for (final part in versions[versionIndex].parts) {
        if (part.streams.isNotEmpty) { streams.addAll(part.streams); break; }
      }
    }
    final video = streams.where((s) => s.kind == MediaStreamKind.video);
    final dv = video.any((s) => s.dolbyVision);
    final hdrPlus = video.any((s) => s.hdr10Plus);
    final hdr10 = video.any((s) => !s.dolbyVision && !s.hdr10Plus &&
        RegExp(r'HDR[ -]?10(?![+])').hasMatch(
          [s.profile, s.title, s.displayTitle].whereType<String>().join(' ').toUpperCase()));
    final preview = _source == null ? null : previewPlaybackTracks(
      item, _source!,
      profile: context.read<AccountPreferencesController?>()?.activePreferences,
    );
    final audioLabel = preview?.audio?.label;
    final audio = [audioLabel?.primary, audioLabel?.secondary].whereType<String>().join(' ').toUpperCase();
    String? audioFile;
    if (audio.contains('ATMOS')) { audioFile = 'dolby_atmos.png'; }
    else if (audio.contains('DTS:X') || audio.contains('DTS X')) { audioFile = 'dts_x.png'; }
    else if ((audio.contains('DTS-HD') || audio.contains('DTS HD')) && (audio.contains('MASTER') || audio.contains(' MA'))) { audioFile = 'dts_hd_master_audio.png'; }
    else if (audio.contains('TRUEHD') || audio.contains('TRUE HD')) { audioFile = 'dolby_truehd.png'; }
    else if (audio.contains('EAC3') || audio.contains('E-AC3') || audio.contains('DOLBY DIGITAL PLUS') || audio.contains('DD+')) { audioFile = 'dolby_digital_plus_5_1.png'; }
    else if (audio.contains('AC3') || audio.contains('AC-3') || audio.contains('DOLBY DIGITAL')) { audioFile = 'dolby_digital_5_1.png'; }
    else if (audio.contains('DTS')) { audioFile = 'dts_5_1.png'; }
    else if (audio.contains('AAC')) { audioFile = 'aac_5_1.png'; }
    else if (audio.contains('STEREO') || audio.contains('2.0')) { audioFile = 'stereo_2_0.png'; }
    final subtitle = preview?.subtitle;
    final lang = [subtitle?.languageCode, subtitle?.language].whereType<String>().join(' ').toLowerCase();
    final forcedEs = subtitle != null && subtitle.forced &&
        RegExp(r'(^|[^a-z])(es|es-es|spa|spanish|español|espanol|castellano)([^a-z]|$)').hasMatch(lang);
    final logos = <String>[
      if (is4K) '4k_uhd.png' else if (fullHd) 'full_hd.png',
      if (dv) 'dolby_vision.png',
      if (hdrPlus) 'hdr10_plus.png',
      if (hdr10) 'hdr10.png',
      if (audioFile != null) audioFile,
      if (forcedEs) 'forzado_es.png',
    ];
    if (logos.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < logos.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Image.asset('assets/hero_badges/${logos[i]}', height: 20, fit: BoxFit.contain,
            filterQuality: FilterQuality.medium),
        ],
      ]),
    );
  }
}
