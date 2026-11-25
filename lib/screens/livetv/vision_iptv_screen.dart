import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../mixins/refreshable.dart';
import '../../mpv/mpv.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/playback_coordinator.dart';
import 'package:provider/provider.dart';
import 'live_tv_screen.dart';

class _Channel {
  const _Channel(this.name, this.group, this.url, this.logo);
  final String name, group, url, logo;
}

List<_Channel> _parsePlaylist(String source, Uri base) {
  final channels = <_Channel>[];
  String? name;
  String group = 'Otros', logo = '';
  for (final raw in const LineSplitter().convert(source)) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF:')) {
      final comma = line.indexOf(',');
      name = comma < 0 ? 'Canal' : line.substring(comma + 1).trim();
      group = RegExp(r'group-title="([^"]*)"').firstMatch(line)?.group(1) ?? 'Otros';
      logo = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line)?.group(1) ?? '';
    } else if (line.isNotEmpty && !line.startsWith('#') && name != null) {
      final uri = base.resolve(line);
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        channels.add(_Channel(name, group.isEmpty ? 'Otros' : group, uri.toString(), logo));
      }
      name = null;
    }
  }
  return channels;
}

class VisionIptvScreen extends StatefulWidget {
  const VisionIptvScreen({super.key});
  @override
  State<VisionIptvScreen> createState() => _VisionIptvScreenState();
}

class _VisionIptvScreenState extends State<VisionIptvScreen> implements FocusableTab, ManualRefreshable {
  final _entry = FocusNode();
  final _url = TextEditingController();
  List<_Channel> _channels = [];
  String? _group;
  String? _error;
  bool _loading = false;
  bool _useExoPlayer = true;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _url.text = prefs.getString('vision_iptv_url') ?? '';
    setState(() => _useExoPlayer = prefs.getBool('vision_iptv_exo') ?? true);
    if (_url.text.isNotEmpty) await _load();
  }

  @override
  void focusActiveTabIfReady() => _entry.requestFocus();
  @override
  void manualRefresh() => unawaited(_load());

  Future<void> _selectPlayer() async {
    final value = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reproductor IPTV'),
        actions: [
          TextButton(autofocus: _useExoPlayer, onPressed: () => Navigator.pop(ctx, true), child: const Text('ExoPlayer')),
          TextButton(autofocus: !_useExoPlayer, onPressed: () => Navigator.pop(ctx, false), child: const Text('MPV')),
        ],
      ),
    );
    if (!mounted || value == null) return;
    setState(() => _useExoPlayer = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('vision_iptv_exo', value);
  }

  Future<void> _configure() async {
    final controller = TextEditingController(text: _url.text);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lista IPTV M3U'),
        content: TextField(controller: controller, autofocus: true, keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'URL de la lista'), onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Guardar')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || value == null) return;
    _url.text = value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vision_iptv_url', _url.text);
    if (mounted) await _load();
  }

  Future<void> _load() async {
    if (_loading || !mounted) return;
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      setState(() => _error = 'Introduce una URL HTTP o HTTPS válida.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw StateError('HTTP');
      final channels = _parsePlaylist(utf8.decode(response.bodyBytes, allowMalformed: true), uri);
      if (channels.isEmpty) throw StateError('Empty');
      if (mounted) setState(() { _channels = channels; _group = null; });
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo cargar la lista IPTV.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _entry.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _channels.map((c) => c.group).toSet().toList();
    final visible = _channels.where((c) => _group == null || c.group == _group).toList();
    return Scaffold(
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('TV en directo · IPTV', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton(focusNode: _entry, onPressed: _loading ? null : _configure, child: const Text('Configurar lista')),
            OutlinedButton(onPressed: _loading ? null : _load, child: const Text('Actualizar')),
            OutlinedButton(onPressed: _selectPlayer, child: Text(_useExoPlayer ? 'Motor: ExoPlayer' : 'Motor: MPV')),
            if (context.watch<MultiServerProvider>().hasLiveTv)
              OutlinedButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: LiveTvScreen()))), child: const Text('TV de Plex')),
          ]),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
          const SizedBox(height: 12),
          Expanded(child: Row(children: [
            SizedBox(width: 190, child: ListView.builder(
              itemCount: groups.length + 1,
              itemBuilder: (_, i) {
                final group = i == 0 ? null : groups[i - 1];
                return ListTile(title: Text(group ?? 'Todos'), selected: _group == group,
                  onTap: () => setState(() => _group = group));
              },
            )),
            const VerticalDivider(),
            Expanded(child: ListView.builder(
              itemCount: visible.length,
              itemBuilder: (_, i) {
                final channel = visible[i];
                return ListTile(
                  leading: channel.logo.isEmpty ? const Icon(Icons.tv) : Image.network(channel.logo,
                    width: 48, height: 36, fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(Icons.tv)),
                  title: Text(channel.name),
                  subtitle: Text(channel.group),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => _IptvPlayer(channel: channel, useExoPlayer: _useExoPlayer))),
                );
              },
            )),
          ])),
        ]),
      )),
    );
  }
}

class _IptvPlayer extends StatefulWidget {
  const _IptvPlayer({required this.channel, required this.useExoPlayer});
  final bool useExoPlayer;
  final _Channel channel;
  @override
  State<_IptvPlayer> createState() => _IptvPlayerState();
}

class _IptvPlayerState extends State<_IptvPlayer> with WidgetsBindingObserver {
  Player? _player;
  StreamSubscription<PlayerError>? _errors;
  StreamSubscription<void>? _frames;
  bool _failed = false, _ready = false, _showName = true;
  Timer? _timer;
  String _technical = '';
  bool _readingStats = false;
  Future<void>? _closing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    try {
      await PlaybackCoordinator.instance.claimVideo();
      if (!mounted || _closing != null) return;
      final player = Player(useExoPlayer: widget.useExoPlayer);
      _player = player;
      _errors = player.streams.error.listen((_) {
        if (mounted) setState(() => _failed = true);
      });
      _frames = player.streams.playbackRestart.listen((_) {
        if (mounted) {
          setState(() { _ready = true; _failed = false; });
          unawaited(_readStats());
        }
      });
      setState(() {});
      await player.open(Media(widget.channel.url), isLive: true);
      if (mounted) _hideLater();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _readStats() async {
    final player = _player;
    if (player == null || _readingStats || _closing != null) return;
    _readingStats = true;
    try {
      final engine = await player.runtimePlayerType();
      final stats = player.providesNativeStats ? await player.getStats() : <String, dynamic>{};
      Future<String> field(String native, String property) async {
        final value = stats[native] ?? stats[property] ?? await player.getProperty(property);
        return value?.toString() ?? '—';
      }
      final values = await Future.wait([
        field('videoWidth', 'video-params/w'),
        field('videoHeight', 'video-params/h'),
        field('videoCodec', 'video-codec'),
        field('videoFps', 'container-fps'),
        field('audioCodec', 'audio-codec-name'),
        field('videoDroppedFrames', 'frame-drop-count'),
      ]);
      if (mounted && _closing == null && identical(player, _player)) {
        setState(() => _technical = '${engine.toUpperCase()} · ${values[0]} × ${values[1]} · ${values[2]} · ${values[3]} fps · Audio: ${values[4]} · Frames perdidos: ${values[5]}');
      }
    } catch (_) {
      // Stats are optional and must never interrupt live playback.
    } finally {
      _readingStats = false;
    }
  }

  void _hideLater() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showName = false);
    });
  }

  Future<void> _close() => _closing ??= _release();
  Future<void> _release() async {
    await _errors?.cancel();
    await _frames?.cancel();
    final player = _player;
    _player = null;
    if (player != null) {
      try { await player.dispose(); } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(_close());
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: Focus(autofocus: true, onKeyEvent: (_, event) {
      if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.select ||
          event.logicalKey == LogicalKeyboardKey.enter)) {
        setState(() => _showName = true);
        unawaited(_readStats());
        _hideLater();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }, child: Stack(fit: StackFit.expand, children: [
      if (_player != null) Video(player: _player!),
      if (!_ready && !_failed) const Center(child: CircularProgressIndicator()),
      if (_failed) const Center(child: Text('No se pudo reproducir el canal. Pulsa Atrás.')),
      if (_showName) Positioned(left: 24, bottom: 24, child: ColoredBox(
        color: Colors.black87, child: Padding(padding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.channel.name, style: const TextStyle(color: Colors.white, fontSize: 22)),
            if (_technical.isNotEmpty) Text(_technical, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ])))),
    ])),
  );
}
