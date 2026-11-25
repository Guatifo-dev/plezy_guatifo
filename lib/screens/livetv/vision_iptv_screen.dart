import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../mixins/refreshable.dart';
import '../../mpv/mpv.dart';
import '../../mpv/player/platform/player_android.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/playback_coordinator.dart';
import 'package:provider/provider.dart';
import 'live_tv_screen.dart';
import '../video_player/wakelock_controller.dart';

class _Channel {
  const _Channel(this.name, this.group, this.url, this.logo, {this.drmType, this.drmLicense, this.manifestType, this.tvgId = ''});
  final String name, group, url, logo;
  final String? drmType, drmLicense, manifestType;
  final String tvgId;
  String get favoriteId => jsonEncode([group, name, tvgId]);
}

List<_Channel> _parsePlaylist(String source, Uri base) {
  final channels = <_Channel>[];
  String? name;
  String group = 'Otros', logo = '', tvgId = '';
  String? drmType, drmLicense, manifestType;
  for (final raw in const LineSplitter().convert(source)) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF:')) {
      drmType = null;
      drmLicense = null;
      manifestType = null;
      tvgId = RegExp(r'tvg-id="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      final comma = line.indexOf(',');
      name = comma < 0 ? 'Canal' : line.substring(comma + 1).trim();
      group = RegExp(r'group-title="([^"]*)"').firstMatch(line)?.group(1) ?? 'Otros';
      logo = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line)?.group(1) ?? '';
    } else if (name != null && line.toUpperCase().startsWith('#KODIPROP:')) {
      final equals = line.indexOf('=');
      if (equals < 0) continue;
      final property = line.substring(10, equals).trim().toLowerCase();
      final value = line.substring(equals + 1).trim();
      if (value.isEmpty) continue;
      switch (property) {
        case 'inputstream.adaptive.license_type':
          drmType = value.toLowerCase();
          break;
        case 'inputstream.adaptive.license_key':
          drmLicense = value;
          break;
        case 'inputstream.adaptive.manifest_type':
          manifestType = value.toLowerCase();
          break;
      }
    } else if (line.isNotEmpty && !line.startsWith('#') && name != null) {
      final uri = base.resolve(line);
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        channels.add(_Channel(name, group.isEmpty ? 'Otros' : group, uri.toString(), logo,
          drmType: drmType, drmLicense: drmLicense, manifestType: manifestType, tvgId: tvgId));
      }
      name = null;
      drmType = null;
      drmLicense = null;
      manifestType = null;
    }
  }
  return channels;
}

final _iptvSettingsChanged = ValueNotifier<int>(0);

void notifyVisionIptvSettingsChanged() => _iptvSettingsChanged.value++;

class _Programme {
  const _Programme(this.title, this.start, this.stop, this.description);
  final String title, description;
  final DateTime start, stop;
}

DateTime? _xmltvDate(String? input) {
  if (input == null) return null;
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-]\d{4}|Z))?').firstMatch(input);
  if (m == null) return null;
  final zone = m[7] ?? 'Z';
  final offset = zone == 'Z' ? 'Z' : '${zone.substring(0, 3)}:${zone.substring(3)}';
  return DateTime.tryParse('${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}$offset');
}

Map<String, List<_Programme>> _parseGuide(List<int> bytes) {
  final raw = bytes.length > 1 && bytes[0] == 31 && bytes[1] == 139 ? gzip.decode(bytes) : bytes;
  final doc = XmlDocument.parse(utf8.decode(raw, allowMalformed: true));
  final result = <String, List<_Programme>>{};
  final now = DateTime.now();
  for (final p in doc.findAllElements('programme')) {
    final id = p.getAttribute('channel');
    final start = _xmltvDate(p.getAttribute('start'));
    final stop = _xmltvDate(p.getAttribute('stop'));
    if (id == null || start == null || stop == null || stop.isBefore(now) || start.isAfter(now.add(const Duration(days: 3)))) continue;
    final titles = p.findElements('title');
    final descriptions = p.findElements('desc');
    (result[id] ??= []).add(_Programme(titles.isEmpty ? '' : titles.first.innerText, start, stop, descriptions.isEmpty ? '' : descriptions.first.innerText));
  }
  for (final entries in result.values) {
    entries.sort((a, b) => a.start.compareTo(b.start));
  }
  return result;
}

String _programmeLine(Map<String, List<_Programme>> guide, _Channel channel) {
  final now = DateTime.now();
  final entries = guide[channel.tvgId] ?? const <_Programme>[];
  for (final p in entries) {
    if (!now.isBefore(p.start) && now.isBefore(p.stop)) {
      final start = p.start.toLocal(), stop = p.stop.toLocal();
      String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
      return '${hm(start)}–${hm(stop)}  ${p.title}';
    }
  }
  return '';
}

class VisionIptvScreen extends StatefulWidget {
  const VisionIptvScreen({super.key, this.settingsOnly = false});
  final bool settingsOnly;
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
  bool _tunneling = false;
  String _buffer = 'minimum';
  bool _forceHls = false;
  String _epgUrl = '', _autoEpg = '', _epgStatus = '';
  Map<String, List<_Programme>> _guide = {};
  Timer? _guideTimer;
  bool _guideLoading = false;
  bool _restoring = false;
  Set<String> _favorites = {};
  bool _favoritesOnly = false;
  _Channel? _focusedChannel;
  _Programme? _focusedProgramme;
  final _guideScroll = ScrollController();
  int _timeShift = 0;
  static const double _channelWidth = 180;
  static const double _rowHeight = 60;


  @override
  void initState() {
    super.initState();
    if (!widget.settingsOnly) {
      _iptvSettingsChanged.addListener(_settingsUpdated);
      _guideTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    unawaited(_restore());
  }

  Future<void> _restore() async {
    if (_restoring) return;
    _restoring = true;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _url.text = prefs.getString('vision_iptv_url') ?? '';
    setState(() {
      _favorites = (prefs.getStringList('vision_iptv_favorites') ?? []).toSet();
      _epgUrl = prefs.getString('vision_iptv_epg') ?? '';
      _useExoPlayer = prefs.getBool('vision_iptv_exo') ?? true;
      _tunneling = prefs.getBool('vision_iptv_tunneling') ?? false;
      _buffer = prefs.getString('vision_iptv_buffer') ?? 'minimum';
      _forceHls = prefs.getBool('vision_iptv_force_hls') ?? false;
    });
    _restoring = false;
    if (!widget.settingsOnly && _url.text.isNotEmpty) await _load();
  }

  void _settingsUpdated() => unawaited(_restore());

  Future<void> _toggleFavorite(_Channel channel) async {
    setState(() {
      if (!_favorites.remove(channel.favoriteId)) _favorites.add(channel.favoriteId);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('vision_iptv_favorites', _favorites.toList());
  }

  void _playChannel(_Channel channel, List<_Channel> visible) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _IptvPlayer(channel: channel, channels: List.unmodifiable(visible),
        guide: _guide, allChannels: List.unmodifiable(_channels), onFavorite: _toggleFavorite, isFavorite: (c) => _favorites.contains(c.favoriteId), useExoPlayer: _useExoPlayer, tunneling: _tunneling,
        buffer: _buffer, forceHls: _forceHls)));
  }

  Future<void> _channelOptions(_Channel channel, List<_Channel> visible) async {
    final favorite = _favorites.contains(channel.favoriteId);
    final action = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text(channel.name),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, 'favorite'),
          child: Text(favorite ? 'Quitar de favoritos' : 'Añadir a favoritos')),
        TextButton(onPressed: () => Navigator.pop(ctx, 'play'), child: const Text('Ver canal')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
      ],
    ));
    if (!mounted) return;
    if (action == 'favorite') await _toggleFavorite(channel);
    if (action == 'play' && mounted) _playChannel(channel, visible);
  }

  String _hm(DateTime date) {
    final d = date.toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Widget _guideCell({required Widget child, required VoidCallback onTap,
      required VoidCallback onOptions, required VoidCallback onFocus, bool current = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(padding: const EdgeInsets.all(2), child: Material(
      color: current ? scheme.primary.withAlpha(55) : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(7),
      clipBehavior: Clip.antiAlias,
      child: Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: (_, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.contextMenu) {
          onOptions();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }, child: _IptvFocusCell(onTap: onTap, onOptions: onOptions, onFocus: onFocus, child: child)),
    ));
  }

  Widget _guideRow(_Channel channel, List<_Channel> visible, DateTime start, double width) {
    final end = start.add(const Duration(hours: 2));
    final entries = (_guide[channel.tvgId] ?? const <_Programme>[])
      .where((p) => p.start.isBefore(end) && p.stop.isAfter(start)).toList();
    final now = DateTime.now();
    double x(DateTime d) => (d.difference(start).inSeconds / 7200 * width).clamp(0.0, width).toDouble();
    void focus(_Programme? p) {
      if (mounted && (_focusedChannel != channel || _focusedProgramme != p)) {
        setState(() { _focusedChannel = channel; _focusedProgramme = p; });
      }
    }
    Widget cell(_Programme? p) => _guideCell(
      onTap: () => _playChannel(channel, visible),
      onOptions: () => _channelOptions(channel, visible),
      onFocus: () => focus(p),
      current: p != null && !now.isBefore(p.start) && now.isBefore(p.stop),
      child: Align(alignment: Alignment.centerLeft, child: Text(p?.title ?? 'Sin programación',
        maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
    );
    return SizedBox(height: _rowHeight, child: Row(children: [
      SizedBox(width: _channelWidth, child: _guideCell(
        onTap: () => _playChannel(channel, visible),
        onOptions: () => _channelOptions(channel, visible),
        onFocus: () => focus(null),
        child: Row(children: [
          SizedBox(width: 35, height: 32, child: channel.logo.isEmpty
            ? const Icon(Icons.tv) : Image.network(channel.logo, fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(Icons.tv))),
          const SizedBox(width: 7),
          Expanded(child: Text(channel.name, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13))),
          if (_favorites.contains(channel.favoriteId)) const Icon(Icons.star, size: 15, color: Colors.amber),
        ]),
      )),
      SizedBox(width: width, child: Stack(fit: StackFit.expand, children: [
        if (entries.isEmpty) cell(null),
        for (final p in entries)
          if (x(p.stop) - x(p.start) > 1)
            Positioned(left: x(p.start), width: x(p.stop) - x(p.start), top: 0, bottom: 0, child: cell(p)),
        if (!now.isBefore(start) && now.isBefore(end))
          Positioned(left: x(now), top: 0, bottom: 0, child: IgnorePointer(child: Container(width: 2, color: Colors.orange))),
      ])),
    ]));
  }

  Widget _buildGuide(List<_Channel> visible) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30)
      .add(Duration(minutes: 30 * _timeShift));
    final scheme = Theme.of(context).colorScheme;
    final selected = _focusedChannel;
    final programme = _focusedProgramme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(height: 100, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(selected?.name ?? 'Guía de televisión', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            if (programme != null) Text('${_hm(programme.start)} – ${_hm(programme.stop)}  ${programme.title}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
            if (programme != null && programme.description.isNotEmpty)
              Expanded(child: Text(programme.description, maxLines: 2, overflow: TextOverflow.ellipsis)),
            if (programme == null) const Text('Selecciona un canal o programa · MENU: opciones'),
          ])),
          if (selected != null) IconButton(
            tooltip: _favorites.contains(selected.favoriteId) ? 'Quitar de favoritos' : 'Añadir a favoritos',
            onPressed: () => _toggleFavorite(selected),
            icon: Icon(_favorites.contains(selected.favoriteId) ? Icons.star : Icons.star_border, color: Colors.amber)),
        ])),
      const SizedBox(height: 6),
      Row(children: [
        TextButton(onPressed: () => setState(() => _timeShift--), child: const Text('‹ 30 min')),
        TextButton(onPressed: () => setState(() => _timeShift = 0), child: const Text('Ahora')),
        TextButton(onPressed: () => setState(() => _timeShift++), child: const Text('30 min ›')),
      ]),
      Expanded(child: LayoutBuilder(builder: (context, constraints) {
        final width = (constraints.maxWidth - _channelWidth).clamp(100.0, 10000.0).toDouble();
        return Column(children: [
          SizedBox(height: 28, child: Row(children: [
            const SizedBox(width: _channelWidth, child: Text('Canales')),
            for (var i = 0; i < 4; i++)
              SizedBox(width: width / 4, child: Text(_hm(start.add(Duration(minutes: 30 * i))))),
          ])),
          Expanded(child: visible.isEmpty
            ? const Center(child: Text('No hay canales en este grupo'))
            : ListView.builder(controller: _guideScroll, itemExtent: _rowHeight,
                itemCount: visible.length, itemBuilder: (_, i) => _guideRow(visible[i], visible, start, width))),
        ]);
      })),
    ]);
  }

  Future<void> _configureEpg() async {
    final controller = TextEditingController(text: _epgUrl);
    final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('URL EPG (XMLTV)'),
      content: TextField(controller: controller, autofocus: true, keyboardType: TextInputType.url,
        decoration: const InputDecoration(hintText: 'Vacío: detección automática'), onSubmitted: (v) => Navigator.pop(ctx, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Guardar')),
      ],
    ));
    controller.dispose();
    if (!mounted || value == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _epgUrl = value.trim());
    await prefs.setString('vision_iptv_epg', _epgUrl);
  }

  Future<void> _loadGuide({bool force = false}) async {
    if (_guideLoading || !mounted) return;
    final url = _epgUrl.isNotEmpty ? _epgUrl : _autoEpg;
    final uri = Uri.tryParse(url);
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) return;
    _guideLoading = true;
    try {
      final dir = await getApplicationCacheDirectory();
      final cache = File('${dir.path}/vision_epg.xml');
      final prefs = await SharedPreferences.getInstance();
      final same = prefs.getString('vision_epg_cache_source') == url;
      if (same && await cache.exists()) {
        final age = DateTime.now().difference(await cache.lastModified());
        try {
          final cached = await compute(_parseGuide, await cache.readAsBytes());
          if (mounted) setState(() { _guide = cached; _epgStatus = 'Guía disponible'; });
          if (!force && age < const Duration(hours: 6)) return;
        } catch (_) {}
      }
      final response = await http.get(uri).timeout(const Duration(seconds: 45));
      if (response.statusCode != 200) throw StateError('EPG HTTP');
      final parsed = await compute(_parseGuide, response.bodyBytes);
      await cache.writeAsBytes(response.bodyBytes, flush: true);
      await prefs.setString('vision_epg_cache_source', url);
      if (mounted) setState(() { _guide = parsed; _epgStatus = 'Guía actualizada'; });
    } catch (_) {
      if (mounted) setState(() => _epgStatus = 'No se pudo actualizar la guía');
    } finally {
      _guideLoading = false;
    }
  }

  @override
  void focusActiveTabIfReady() => _entry.requestFocus();
  @override
  void manualRefresh() => unawaited(_load());

  Future<void> _toggleFormat() async {
    setState(() => _forceHls = !_forceHls);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('vision_iptv_force_hls', _forceHls);
  }

  Future<void> _toggleTunneling() async {
    setState(() => _tunneling = !_tunneling);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('vision_iptv_tunneling', _tunneling);
  }

  String get _bufferLabel => _buffer == 'normal' ? 'Normal' : _buffer == 'small' ? 'Pequeño' : 'Mínimo (0)';

  Future<void> _selectBuffer() async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Búfer IPTV (MPV)'),
        actions: [
          for (final entry in const {'minimum': 'Mínimo (0)', 'small': 'Pequeño', 'normal': 'Normal'}.entries)
            TextButton(autofocus: _buffer == entry.key, onPressed: () => Navigator.pop(ctx, entry.key), child: Text(entry.value)),
        ],
      ),
    );
    if (!mounted || value == null) return;
    setState(() => _buffer = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vision_iptv_buffer', value);
  }

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
    if (mounted && !widget.settingsOnly) await _load();
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
      final source = utf8.decode(response.bodyBytes, allowMalformed: true);
      final header = const LineSplitter().convert(source).firstWhere((line) => line.startsWith('#EXTM3U'), orElse: () => '');
      final auto = RegExp(r'(?:x-tvg-url|url-tvg|tvg-url)="([^"]+)"', caseSensitive: false).firstMatch(header)?.group(1);
      _autoEpg = auto == null ? '' : uri.resolve(auto.split(',').first.trim()).toString();
      final channels = _parsePlaylist(source, uri);
      if (channels.isEmpty) throw StateError('Empty');
      if (mounted) setState(() { _channels = channels; _group = null; _guide = {}; });
      if (mounted) unawaited(_loadGuide());
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo cargar la lista IPTV.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    if (!widget.settingsOnly) _iptvSettingsChanged.removeListener(_settingsUpdated);
    _guideTimer?.cancel();
    _guideScroll.dispose();
    _entry.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.settingsOnly) return Scaffold(
      appBar: AppBar(title: const Text('Ajustes IPTV')),
      body: SafeArea(child: ListView(children: [
        ListTile(autofocus: true, title: const Text('Lista M3U'), subtitle: Text(_url.text.isEmpty ? 'Sin configurar' : 'Configurada'), onTap: _configure),
        ListTile(title: const Text('URL EPG'), subtitle: Text(_epgUrl.isEmpty ? 'Automática desde M3U' : 'Configuración manual'), onTap: _configureEpg),
        ListTile(title: const Text('Reproductor IPTV'), subtitle: Text(_useExoPlayer ? 'ExoPlayer' : 'MPV'), onTap: _selectPlayer),
        if (!_useExoPlayer) ListTile(title: const Text('Búfer'), subtitle: Text(_bufferLabel), onTap: _selectBuffer),
        if (_useExoPlayer) ListTile(title: const Text('Formato'), subtitle: Text(_forceHls ? 'HLS' : 'Auto'), onTap: _toggleFormat),
        if (_useExoPlayer) ListTile(title: const Text('Tunneling'), subtitle: Text(_tunneling ? 'Sí' : 'No'), onTap: _toggleTunneling),
        ListTile(title: const Text('Actualizar lista y guía'), subtitle: Text(_epgStatus), onTap: () async { await _load(); if (mounted) await _loadGuide(force: true); }),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) ListTile(title: Text(_error!)),
      ])),
    );
    final groups = _channels.map((c) => c.group).toSet().toList();
    final visible = _channels.where((c) => _favoritesOnly ? _favorites.contains(c.favoriteId) : (_group == null || c.group == _group)).toList();
    return Scaffold(
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('TV en directo · IPTV', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          if (_channels.isEmpty && !_loading)
            FilledButton(focusNode: _entry, onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VisionIptvScreen(settingsOnly: true)));
              if (mounted) _iptvSettingsChanged.value++;
            }, child: const Text('Ajustes IPTV'))
          else
            Row(children: [
              Text(_epgStatus),
              const Spacer(),
              if (context.watch<MultiServerProvider>().hasLiveTv)
                OutlinedButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: LiveTvScreen()))), child: const Text('TV de Plex')),
            ]),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
          const SizedBox(height: 12),
          Expanded(child: Row(children: [
            SizedBox(width: 160, child: ListView.builder(
              itemCount: groups.length + 2,
              itemBuilder: (_, i) {
                final group = i < 2 ? null : groups[i - 2];
                return ListTile(focusNode: i == 0 && _channels.isNotEmpty ? _entry : null,
                  leading: i == 1 ? const Icon(Icons.star, color: Colors.amber) : null,
                  title: Text(i == 1 ? 'Favoritos' : group ?? 'Todos', maxLines: 2, overflow: TextOverflow.ellipsis),
                  selected: i == 1 ? _favoritesOnly : !_favoritesOnly && _group == group,
                  onTap: () {
                    setState(() { _favoritesOnly = i == 1; _group = group; _focusedChannel = null; _focusedProgramme = null; });
                    if (_guideScroll.hasClients) _guideScroll.jumpTo(0);
                  });
              },
            )),
            const VerticalDivider(width: 12),
            Expanded(child: _buildGuide(visible)),
          ])),
        ]),
      )),
    );
  }
}

class _IptvPlayer extends StatefulWidget {
  const _IptvPlayer({required this.channel, required this.channels, required this.guide, required this.allChannels, required this.onFavorite, required this.isFavorite, required this.useExoPlayer, required this.tunneling, required this.buffer, required this.forceHls});
  final bool forceHls;
  final String buffer;
  final bool tunneling;
  final bool useExoPlayer;
  final _Channel channel;
  final List<_Channel> channels;
  final Map<String, List<_Programme>> guide;
  final List<_Channel> allChannels;
  final Future<void> Function(_Channel) onFavorite;
  final bool Function(_Channel) isFavorite;
  @override
  State<_IptvPlayer> createState() => _IptvPlayerState();
}

class _IptvPlayerState extends State<_IptvPlayer> with WidgetsBindingObserver {
  final _wakelock = WakelockController();
  final _startup = Stopwatch();
  Player? _player;
  StreamSubscription<PlayerError>? _errors;
  StreamSubscription<void>? _frames;
  bool _failed = false, _ready = false, _showName = true;
  Timer? _timer;
  String _technical = '';
  bool _readingStats = false;
  Future<void>? _closing;
  late int _channelIndex;
  late int _highlightIndex;
  bool _switching = true, _showChannels = false, _preview = true;
  final _playerFocus = FocusNode();
  final _previewScroll = ScrollController();
  bool _technicalVisible = false;
  _Programme? get _currentProgramme {
    final now = DateTime.now();
    for (final p in widget.guide[_channel.tvgId] ?? const <_Programme>[]) {
      if (!now.isBefore(p.start) && now.isBefore(p.stop)) return p;
    }
    return null;
  }
  _Programme? get _nextProgramme {
    final now = DateTime.now();
    for (final p in widget.guide[_channel.tvgId] ?? const <_Programme>[]) {
      if (p.start.isAfter(now)) return p;
    }
    return null;
  }
  String _clock(DateTime date) {
    final d = date.toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  void _previewMode(bool value) {
    setState(() { _preview = value; _showChannels = false; _highlightIndex = _channelIndex; _showName = true; });
    if (value) {
      _timer?.cancel();
      _scrollPreview();
    } else { _hideLater(); }
    _playerFocus.requestFocus();
  }
  void _scrollPreview() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_preview || !_previewScroll.hasClients) return;
      final p = _previewScroll.position;
      _previewScroll.jumpTo((_highlightIndex * 54.0 - p.viewportDimension / 2 + 27).clamp(0.0, p.maxScrollExtent).toDouble());
    });
  }
  Future<void> _options() async {
    final selected = _preview || _showChannels ? widget.channels[_highlightIndex] : _channel;
    final action = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text(selected.name), actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, 'favorite'), child: Text(widget.isFavorite(selected) ? 'Quitar de favoritos' : 'Añadir a favoritos')),
        TextButton(onPressed: () => Navigator.pop(ctx, 'technical'), child: const Text('Información técnica')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
      ]));
    if (!mounted) return;
    if (action == 'favorite') { await widget.onFavorite(selected); if (mounted) setState(() {}); }
    if (action == 'technical' && mounted) { await _readStats(); if (mounted) { setState(() { _technicalVisible = true; _showName = true; }); _hideLater(); } }
    if (mounted) _playerFocus.requestFocus();
  }
  final _channelScroll = ScrollController();
  _Channel get _channel => widget.channels[_channelIndex];

  @override
  void initState() {
    super.initState();
    _channelIndex = widget.channels.indexOf(widget.channel);
    if (_channelIndex < 0) _channelIndex = 0;
    _highlightIndex = _channelIndex;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) { _scrollPreview(); unawaited(_start()); } });
  }

  Future<void> _start() async {
    try {
      if (!mounted || _closing != null) return;
      _startup.start();
      unawaited(_wakelock.setEnabled(true));
      await PlaybackCoordinator.instance.claimVideo();
      debugPrint('[VisionIPTV] claim: ${_startup.elapsedMilliseconds} ms');
      if (!mounted || _closing != null) return;
      final player = Player(useExoPlayer: widget.useExoPlayer, hardwareDecoding: true);
      _player = player;
      _errors = player.streams.error.listen((_) {
        if (mounted) setState(() => _failed = true);
      });
      _frames = player.streams.playbackRestart.listen((_) {
        if (mounted) {
          if (!_ready) {
            debugPrint('[VisionIPTV] playback restart: ${_startup.elapsedMilliseconds} ms');
          }
          setState(() { _ready = true; _failed = false; });
          unawaited(_readStats());
        }
      });
      setState(() {});
      try {
        if (widget.useExoPlayer) {
          await player.setProperty('tunneled-playback', widget.tunneling ? 'yes' : 'no');
          await player.setProperty('hwdec', 'mediacodec,mediacodec-copy');
        } else {
          await player.setProperty('hwdec', 'mediacodec,mediacodec-copy');
          if (widget.buffer != 'normal') {
            final minimum = widget.buffer == 'minimum';
            for (final entry in <String, String>{
              'cache-pause-initial': minimum ? 'no' : 'yes',
              'cache-pause-wait': minimum ? '0' : '1',
              'cache-secs': minimum ? '1' : '3',
            }.entries) {
              try {
                await player.setProperty(entry.key, entry.value);
              } catch (error) {
                debugPrint('[VisionIPTV] buffer property ${entry.key}: $error');
              }
            }
          }
          debugPrint('[VisionIPTV] MPV buffer: ${widget.buffer}');
        }
      } catch (_) {
        // Keep the backend default if an optional setting is unsupported.
      }
      if (!mounted || _closing != null) return;
      await _openChannel(player);
    } catch (error) {
      debugPrint('[VisionDRM] playback preparation failed: ${error.runtimeType}');
      unawaited(_wakelock.setEnabled(false));
      if (mounted) setState(() => _failed = true);
    } finally {
      _switching = false;
    }
  }

  Future<void> _openChannel(Player player) async {
      debugPrint('[VisionIPTV] opening: ${_startup.elapsedMilliseconds} ms');
      final path = Uri.parse(_channel.url).path.toLowerCase();
      final isDash = path.endsWith('.mpd') || _channel.manifestType == 'mpd' || _channel.manifestType == 'dash';
      // Media3 infers DASH from the manifest URI when no HLS MIME is forced.
      final forceLiveHls = !widget.useExoPlayer ||
          (!isDash && (widget.forceHls || path.endsWith('.m3u8')));
      if (widget.useExoPlayer) {
        final format = isDash ? 'DASH' : (forceLiveHls ? 'HLS' : 'Auto');
        debugPrint('[VisionIPTV] Exo format: $format');
      }
      debugPrint('[VisionDRM] preparing playback');
      final drmType = _channel.drmType;
      final license = _channel.drmLicense;
      final clearKey = drmType == 'clearkey' || drmType == 'org.w3.clearkey';
      debugPrint('[VisionDRM] DASH=$isDash DRM recognized=$clearKey license present=${license != null && license.isNotEmpty}');
      if (widget.useExoPlayer && player is PlayerAndroid && (isDash || clearKey)) {
        String? localLicense;
        String? licenseUrl;
        if (clearKey) {
          if (license == null || license.isEmpty) throw StateError('Missing ClearKey license');
          final licenseUri = Uri.tryParse(license);
          if (licenseUri != null && ['http', 'https'].contains(licenseUri.scheme) && licenseUri.host.isNotEmpty) {
            licenseUrl = license;
          } else if (license.startsWith('{')) {
            final decoded = jsonDecode(license);
            if (decoded is! Map || decoded['keys'] is! List) throw StateError('Invalid ClearKey license');
            localLicense = jsonEncode(decoded);
          } else {
            String encodeHex(String hex) {
              if (hex.length != 32 || RegExp(r'[^0-9a-fA-F]').hasMatch(hex)) throw StateError('Invalid ClearKey value');
              return base64UrlEncode(List<int>.generate(16, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16))).replaceAll('=', '');
            }
            final pair = license.split(':');
            if (pair.length != 2) throw StateError('Unsupported ClearKey license');
            localLicense = jsonEncode({'keys': [{'kty': 'oct', 'kid': encodeHex(pair[0].trim()), 'k': encodeHex(pair[1].trim())}], 'type': 'temporary'});
          }
        }
        debugPrint('[VisionDRM] invoking native player');
        await player.open(Media(_channel.url), isLive: false, dashManifest: true,
          clearKeyLicense: localLicense, clearKeyLicenseUrl: licenseUrl);
      } else {
        await player.open(Media(_channel.url), isLive: forceLiveHls);
      }
      debugPrint('[VisionDRM] open returned');
      debugPrint('[VisionIPTV] open returned: ${_startup.elapsedMilliseconds} ms');
      if (mounted) _hideLater();
  }

  Future<void> _switchChannel(int index) async {
    final player = _player;
    if (!mounted || _closing != null || _switching || player == null || widget.channels.isEmpty) return;
    final next = (index % widget.channels.length + widget.channels.length) % widget.channels.length;
    if (next == _channelIndex && !_failed) return;
    _timer?.cancel();
    setState(() {
      _switching = true;
      _channelIndex = next;
      _highlightIndex = next;
      _showChannels = false;
      _ready = false;
      _failed = false;
      _showName = true;
      _technical = '';
      _technicalVisible = false;
    });
    _startup..reset()..start();
    try {
      await player.stop();
      if (!mounted || _closing != null) return;
      unawaited(_wakelock.setEnabled(true));
      await _openChannel(player);
    } catch (error) {
      debugPrint('[VisionIPTV] channel switch failed: ${error.runtimeType}');
      if (mounted && _closing == null) setState(() => _failed = true);
    } finally {
      _switching = false;
    }
  }

  void _scrollToHighlight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showChannels || !_channelScroll.hasClients) return;
      final position = _channelScroll.position;
      final target = (_highlightIndex * 56.0 - position.viewportDimension / 2 + 28)
          .clamp(0.0, position.maxScrollExtent).toDouble();
      _channelScroll.jumpTo(target);
    });
  }

  void _toggleChannels() {
    setState(() {
      _showChannels = !_showChannels;
      _highlightIndex = _channelIndex;
    });
    if (_showChannels) {
      _timer?.cancel();
      _scrollToHighlight();
    } else {
      _hideLater();
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
      final decoder = engine.toLowerCase() == 'mpv' ? await field('hwdec-current', 'hwdec-current') : (stats['videoDecoderName']?.toString() ?? '—');
      if (widget.useExoPlayer) {
        debugPrint('[VisionIPTV] requested ExoPlayer; actual: $engine; decoder: $decoder; stats engine: ${stats['playerType']}');
      }
      final tunnel = stats['tunneledPlayback'];
      final tunnelInfo = tunnel is bool ? (tunnel ? ' · Tunneling activo' : ' · Tunneling inactivo') : '';
      if (mounted && _closing == null && identical(player, _player)) {
        setState(() => _technical = '${engine.toUpperCase()} · ${values[0]} × ${values[1]} · ${values[2]} · ${values[3]} fps · Audio: ${values[4]} · Frames perdidos: ${values[5]}\nDecodificador: $decoder$tunnelInfo');
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
    unawaited(_wakelock.setEnabled(false));
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
    _channelScroll.dispose();
    _previewScroll.dispose();
    _playerFocus.dispose();
    unawaited(_close());
    super.dispose();
  }

  Widget _previewDetails() {
    final channel = widget.channels[_highlightIndex];
    final line = _programmeLine(widget.guide, channel);
    final now = DateTime.now();
    final entries = widget.guide[channel.tvgId] ?? const <_Programme>[];
    _Programme? current;
    for (final p in entries) { if (!now.isBefore(p.start) && now.isBefore(p.stop)) { current = p; break; } }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
      if (line.isNotEmpty) Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
      if (current != null) Expanded(child: Text(current.description, maxLines: 4, overflow: TextOverflow.ellipsis)),
      const Text('OK: sintonizar / pantalla completa · MENU: opciones', style: TextStyle(fontSize: 12)),
    ]);
  }

  Widget _previewGuide() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30);
    final end = start.add(const Duration(hours: 2));
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (_, constraints) {
      final width = (constraints.maxWidth - 190).clamp(1.0, 10000.0).toDouble();
      double x(DateTime d) => (d.difference(start).inSeconds / 7200 * width).clamp(0.0, width).toDouble();
      return Column(children: [
        SizedBox(height: 25, child: Row(children: [
          const SizedBox(width: 190, child: Text('Canales')),
          for (var i = 0; i < 4; i++) SizedBox(width: width / 4, child: Text(_clock(start.add(Duration(minutes: 30 * i))))),
        ])),
        Expanded(child: ListView.builder(controller: _previewScroll, itemExtent: 54,
          itemCount: widget.channels.length, itemBuilder: (_, i) {
            final channel = widget.channels[i];
            final focused = i == _highlightIndex;
            final programmes = (widget.guide[channel.tvgId] ?? const <_Programme>[]).where((p) => p.start.isBefore(end) && p.stop.isAfter(start));
            final foreground = focused ? Colors.black : scheme.onSurface;
            return Row(children: [
              Container(width: 190, margin: const EdgeInsets.symmetric(vertical: 2), padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: focused ? const Color(0xFF90CAF9) : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
                child: Row(children: [
                  SizedBox(width: 34, height: 30, child: channel.logo.isEmpty ? Icon(Icons.tv, color: foreground) : Image.network(channel.logo, fit: BoxFit.contain, errorBuilder: (_, _, _) => Icon(Icons.tv, color: foreground))),
                  const SizedBox(width: 8),
                  Expanded(child: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: foreground))),
                  if (i == _channelIndex) Icon(Icons.play_arrow, color: foreground, size: 16),
                  if (widget.isFavorite(channel)) const Icon(Icons.star, color: Colors.amber, size: 15),
                ])),
              SizedBox(width: width, child: Stack(fit: StackFit.expand, children: [
                for (final p in programmes)
                  if (x(p.stop) - x(p.start) > 3) Positioned(left: x(p.start), width: x(p.stop) - x(p.start), top: 2, bottom: 2,
                    child: Container(margin: const EdgeInsets.symmetric(horizontal: 2), padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(color: focused ? const Color(0xFF90CAF9) : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
                      child: Align(alignment: Alignment.centerLeft, child: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: foreground, fontSize: 12))))),
                Positioned(left: x(now), top: 0, bottom: 0, child: Container(width: 2, color: Colors.orange)),
              ])),
            ]);
          })),
      ]);
    });
  }

  Widget _infoBanner() {
    final current = _currentProgramme, next = _nextProgramme;
    final now = DateTime.now();
    final progress = current == null ? 0.0 : (now.difference(current.start).inSeconds / current.stop.difference(current.start).inSeconds.clamp(1, 9999999)).clamp(0.0, 1.0).toDouble();
    final number = widget.allChannels.indexOf(_channel) + 1;
    return Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xED10151D), borderRadius: BorderRadius.circular(14)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        SizedBox(width: 58, height: 48, child: _channel.logo.isEmpty ? const Icon(Icons.tv, color: Colors.white) : Image.network(_channel.logo, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.tv, color: Colors.white))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${number.toString().padLeft(3, '0')} · ${_channel.name}', style: const TextStyle(color: Colors.white, fontSize: 18)),
          if (current != null) Text(current.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.bold)),
        ])),
        if (widget.isFavorite(_channel)) const Icon(Icons.star, color: Colors.amber),
        const SizedBox(width: 12),
        Text(_clock(now), style: const TextStyle(color: Colors.white, fontSize: 20)),
      ]),
      if (current != null) ...[
        const SizedBox(height: 8),
        Row(children: [Text(_clock(current.start), style: const TextStyle(color: Colors.white70)), const Spacer(), Text(_clock(current.stop), style: const TextStyle(color: Colors.white70))]),
        LinearProgressIndicator(value: progress, color: Colors.orange, backgroundColor: Colors.white24),
      ],
      if (next != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('A continuación · ${_clock(next.start)} · ${next.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70))),
      if (_technicalVisible && _technical.isNotEmpty) Text(_technical, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    ]));
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _preview && !_showChannels,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _showChannels) { _toggleChannels(); }
      else if (!didPop && !_preview) { _previewMode(true); }
    },
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(focusNode: _playerFocus, autofocus: true, onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.contextMenu) { unawaited(_options()); return KeyEventResult.handled; }
        if (_preview) {
          if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
            setState(() => _highlightIndex = (_highlightIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(0, widget.channels.length - 1).toInt());
            _scrollPreview();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
            if (_highlightIndex == _channelIndex && !_failed) { _previewMode(false); }
            else { unawaited(_switchChannel(_highlightIndex)); }
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowRight) { _previewMode(false); return KeyEventResult.handled; }
          if (key == LogicalKeyboardKey.arrowLeft) return KeyEventResult.handled;
          return KeyEventResult.ignored;
        }
        if (key == LogicalKeyboardKey.arrowLeft) { _previewMode(true); return KeyEventResult.handled; }
        if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
          final delta = key == LogicalKeyboardKey.arrowUp ? 1 : -1;
          if (_showChannels) {
            setState(() => _highlightIndex = (_highlightIndex - delta)
                .clamp(0, widget.channels.length - 1).toInt());
            _scrollToHighlight();
          } else {
            unawaited(_switchChannel(_channelIndex + delta));
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
          if (_showChannels) {
            if (_highlightIndex == _channelIndex && !_failed) {
              _toggleChannels();
            } else {
              unawaited(_switchChannel(_highlightIndex));
            }
          } else {
            _toggleChannels();
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.escape && _showChannels) {
          _toggleChannels();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          setState(() => _showName = true);
          unawaited(_readStats());
          _hideLater();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }, child: Stack(fit: StackFit.expand, children: [
        if (_preview) Positioned.fill(child: ColoredBox(color: Theme.of(context).colorScheme.surface)),
        if (_preview) Positioned(left: 20, right: 340, top: 20, height: 150, child: _previewDetails()),
        if (_preview) Positioned(left: 20, right: 20, top: 184, bottom: 20, child: _previewGuide()),
        if (_player != null) Positioned(
          key: const ValueKey('vision-iptv-video'),
          top: _preview ? 16 : 0, right: _preview ? 20 : 0,
          left: _preview ? null : 0, bottom: _preview ? null : 0,
          width: _preview ? 288 : null, height: _preview ? 162 : null,
          child: Video(player: _player!)),
        if (!_ready && !_failed) Positioned(
          top: _preview ? 70 : 0, right: _preview ? 130 : 0,
          left: _preview ? null : 0, bottom: _preview ? null : 0,
          child: const Center(child: CircularProgressIndicator())),
        if (_failed) Positioned(top: _preview ? 70 : 0, right: _preview ? 20 : 0,
          left: _preview ? null : 0, bottom: _preview ? null : 0,
          child: const Center(child: Text('No se pudo reproducir el canal.'))),
        if (!_preview && _showName && !_showChannels) Positioned(left: 24, right: 24, bottom: 24, child: _infoBanner()),
        if (_preview && _technicalVisible && _showName) Positioned(left: 20, bottom: 20, right: 20, child: ColoredBox(color: Colors.black87, child: Padding(padding: const EdgeInsets.all(12), child: Text(_technical, style: const TextStyle(color: Colors.white))))),
        if (_showChannels) Align(alignment: Alignment.centerLeft, child: SizedBox(
          width: 340,
          child: ColoredBox(color: const Color(0xEB000000),
            child: SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.all(16), child: Text('Canales IPTV', style: TextStyle(color: Colors.white, fontSize: 22))),
              Expanded(child: ListView.builder(
                controller: _channelScroll,
                itemExtent: 56,
                itemCount: widget.channels.length,
                itemBuilder: (_, index) {
                  final channel = widget.channels[index];
                  final focused = index == _highlightIndex;
                  final current = index == _channelIndex;
                  return Container(
                    color: focused ? Colors.blue.shade700 : Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      SizedBox(width: 32, child: Text('${index + 1}', style: const TextStyle(color: Colors.white70))),
                      SizedBox(width: 40, height: 32, child: channel.logo.isEmpty
                        ? const Icon(Icons.tv, color: Colors.white70)
                        : Image.network(channel.logo, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.tv, color: Colors.white70))),
                      const SizedBox(width: 10),
                      Expanded(child: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white))),
                      if (current) const Icon(Icons.play_arrow, color: Colors.white),
                    ]),
                  );
                },
              )),
              const Padding(padding: EdgeInsets.all(12), child: Text('OK: sintonizar · Atrás: cerrar', style: TextStyle(color: Colors.white70))),
            ])),
          ),
        )),
      ])),
    ),
  );
}

class _IptvFocusCell extends StatefulWidget {
  const _IptvFocusCell({required this.onTap, required this.onOptions, required this.onFocus, required this.child});
  final VoidCallback onTap, onOptions, onFocus;
  final Widget child;
  @override
  State<_IptvFocusCell> createState() => _IptvFocusCellState();
}
class _IptvFocusCellState extends State<_IptvFocusCell> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: widget.onTap, onLongPress: widget.onOptions,
    onFocusChange: (value) {
      if (!mounted) return;
      setState(() => _focused = value);
      if (value) {
        WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _focused) { widget.onFocus(); Scrollable.ensureVisible(context, duration: Duration.zero); } });
      }
    },
    focusColor: Colors.transparent,
    child: ColoredBox(color: _focused ? const Color(0xFF90CAF9) : Colors.transparent,
      child: DefaultTextStyle.merge(style: TextStyle(color: _focused ? Colors.black : Theme.of(context).colorScheme.onSurface),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: widget.child))),
  );
}
