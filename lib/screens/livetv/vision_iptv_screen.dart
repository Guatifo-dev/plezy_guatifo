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
  String? _error;
  bool _loading = false;
  bool _useExoPlayer = true;
  bool _tunneling = false;
  String _buffer = 'minimum';
  bool _forceHls = false;
  String _epgUrl = '', _autoEpg = '', _epgStatus = '';
  Map<String, List<_Programme>> _guide = {};
  final _guideNotifier = ValueNotifier<Map<String, List<_Programme>>>({});
  Timer? _guideTimer;
  bool _guideLoading = false;
  bool _restoring = false;
  Set<String> _favorites = {};


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

  bool _guideOpen = false;
  bool _openWhenLoaded = false;
  Future<void> _openUnifiedGuide() async {
    if (!mounted || _guideOpen || _channels.isEmpty) return;
    _guideOpen = true;
    _openWhenLoaded = false;
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => _IptvPlayer(channel: _channels.first, channels: List.unmodifiable(_channels),
          guide: _guide, guideSource: _guideNotifier, allChannels: List.unmodifiable(_channels),
          onFavorite: _toggleFavorite, isFavorite: (c) => _favorites.contains(c.favoriteId),
          useExoPlayer: _useExoPlayer, tunneling: _tunneling, buffer: _buffer, forceHls: _forceHls)));
    } finally {
      _guideOpen = false;
      if (mounted) _entry.requestFocus();
    }
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
          if (mounted) { setState(() { _guide = cached; _epgStatus = 'Guía disponible'; }); _guideNotifier.value = cached; }
          if (!force && age < const Duration(hours: 6)) return;
        } catch (_) {}
      }
      final response = await http.get(uri).timeout(const Duration(seconds: 45));
      if (response.statusCode != 200) throw StateError('EPG HTTP');
      final parsed = await compute(_parseGuide, response.bodyBytes);
      await cache.writeAsBytes(response.bodyBytes, flush: true);
      await prefs.setString('vision_epg_cache_source', url);
      if (mounted) { setState(() { _guide = parsed; _epgStatus = 'Guía actualizada'; }); _guideNotifier.value = parsed; }
    } catch (_) {
      if (mounted) setState(() => _epgStatus = 'No se pudo actualizar la guía');
    } finally {
      _guideLoading = false;
    }
  }

  @override
  void focusActiveTabIfReady() {
    _entry.requestFocus();
    if (!widget.settingsOnly && !_guideOpen) {
      if (_channels.isEmpty) { _openWhenLoaded = true; }
      else { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _entry.hasFocus) unawaited(_openUnifiedGuide()); }); }
    }
  }
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
      if (mounted) {
        setState(() { _channels = channels; _guide = {}; });
        _guideNotifier.value = {};
        if (_openWhenLoaded) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _entry.hasFocus) unawaited(_openUnifiedGuide()); });
      }
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
    _guideNotifier.dispose();
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
    return Scaffold(body: SafeArea(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text('TV en directo · IPTV', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 14),
      if (_loading) const CircularProgressIndicator(),
      if (_error != null) Text(_error!),
      if (_channels.isNotEmpty)
        FilledButton(focusNode: _entry, autofocus: true, onPressed: _openUnifiedGuide, child: const Text('Abrir guía de televisión'))
      else if (!_loading)
        FilledButton(focusNode: _entry, onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VisionIptvScreen(settingsOnly: true)));
          if (mounted) _iptvSettingsChanged.value++;
        }, child: const Text('Ajustes IPTV')),
      if (context.watch<MultiServerProvider>().hasLiveTv)
        TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: LiveTvScreen()))), child: const Text('TV de Plex')),
    ]))));
  }

}

class _IptvPlayer extends StatefulWidget {
  const _IptvPlayer({required this.channel, required this.channels, required this.guide, required this.guideSource, required this.allChannels, required this.onFavorite, required this.isFavorite, required this.useExoPlayer, required this.tunneling, required this.buffer, required this.forceHls});
  final bool forceHls;
  final String buffer;
  final bool tunneling;
  final bool useExoPlayer;
  final _Channel channel;
  final List<_Channel> channels;
  final Map<String, List<_Programme>> guide;
  final ValueNotifier<Map<String, List<_Programme>>> guideSource;
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
  bool _switching = false, _showChannels = false, _preview = true, _tuned = false;
  int _groupIndex = 0, _programmeIndex = -1, _timeShift = 0;
  bool _groupFocus = false;
  Map<String, List<_Programme>> get _guide => widget.guideSource.value;
  List<String> get _groups => ['Todos', 'Favoritos', ...widget.channels.map((c) => c.group).toSet()];
  List<int> get _visibleIndices => [for (var i = 0; i < widget.channels.length; i++) if (_groupIndex == 0 || (_groupIndex == 1 ? widget.isFavorite(widget.channels[i]) : widget.channels[i].group == _groups[_groupIndex])) i];
  DateTime get _windowStart {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30).add(Duration(minutes: 30 * _timeShift));
  }
  List<_Programme> _programmes(int index) {
    final start = _windowStart, end = start.add(const Duration(hours: 2));
    return (_guide[widget.channels[index].tvgId] ?? const <_Programme>[]).where((p) => p.start.isBefore(end) && p.stop.isAfter(start)).toList();
  }
  void _guideChanged() { if (mounted) setState(() {}); }
  void _selectGroup(int index) {
    setState(() { _groupIndex = index.clamp(0, _groups.length - 1).toInt(); final rows = _visibleIndices; if (rows.isNotEmpty) _highlightIndex = rows.first; _programmeIndex = -1; });
    _scrollPreview();
  }
  void _moveRow(int delta) {
    final rows = _visibleIndices;
    if (rows.isEmpty) return;
    final previous = _programmes(_highlightIndex);
    final selectedTime = _programmeIndex >= 0 && _programmeIndex < previous.length ? previous[_programmeIndex].start : null;
    setState(() {
      final row = (rows.indexOf(_highlightIndex) + delta).clamp(0, rows.length - 1).toInt();
      _highlightIndex = rows[row];
      final programmes = _programmes(_highlightIndex);
      if (selectedTime == null || programmes.isEmpty) { _programmeIndex = -1; }
      else { final match = programmes.indexWhere((p) => !selectedTime.isBefore(p.start) && selectedTime.isBefore(p.stop)); _programmeIndex = match < 0 ? 0 : match; }
    });
    _scrollPreview();
  }
  Future<void> _confirmGuide() async {
    if (_groupFocus) { if (_visibleIndices.isNotEmpty) setState(() => _groupFocus = false); return; }
    if (_visibleIndices.isEmpty || _switching) return;
    if (!_tuned) {
      setState(() { _channelIndex = _highlightIndex; _tuned = true; _switching = true; });
      await _start();
    } else if (_highlightIndex == _channelIndex && !_failed) { _previewMode(false); }
    else { await _switchChannel(_highlightIndex); }
  }
  final _playerFocus = FocusNode();
  final _previewScroll = ScrollController();
  bool _technicalVisible = false;
  _Programme? get _currentProgramme {
    final now = DateTime.now();
    for (final p in _guide[_channel.tvgId] ?? const <_Programme>[]) {
      if (!now.isBefore(p.start) && now.isBefore(p.stop)) return p;
    }
    return null;
  }
  _Programme? get _nextProgramme {
    final now = DateTime.now();
    for (final p in _guide[_channel.tvgId] ?? const <_Programme>[]) {
      if (p.start.isAfter(now)) return p;
    }
    return null;
  }
  String _clock(DateTime date) {
    final d = date.toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  void _previewMode(bool value) {
    setState(() { _preview = value; _showChannels = false; _highlightIndex = _channelIndex; _programmeIndex = -1; _groupFocus = false; _showName = true; if (!_visibleIndices.contains(_channelIndex)) _groupIndex = 0; });
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
      _previewScroll.jumpTo((_visibleIndices.indexOf(_highlightIndex) * 54.0 - p.viewportDimension / 2 + 27).clamp(0.0, p.maxScrollExtent).toDouble());
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
    widget.guideSource.addListener(_guideChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _scrollPreview(); });
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
      _programmeIndex = -1;
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
    widget.guideSource.removeListener(_guideChanged);
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
    final programmes = _programmes(_highlightIndex);
    final selected = _programmeIndex >= 0 && _programmeIndex < programmes.length ? programmes[_programmeIndex] : null;
    final line = selected == null ? _programmeLine(_guide, channel) : '${_clock(selected.start)} – ${_clock(selected.stop)}  ${selected.title}';
    final now = DateTime.now();
    final entries = _guide[channel.tvgId] ?? const <_Programme>[];
    _Programme? current;
    for (final p in entries) { if (!now.isBefore(p.start) && now.isBefore(p.stop)) { current = p; break; } }
    current = selected ?? current;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
      if (line.isNotEmpty) Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
      if (current != null) Expanded(child: Text(current.description, maxLines: 4, overflow: TextOverflow.ellipsis)),
      const Text('OK: sintonizar / pantalla completa · MENU: opciones', style: TextStyle(fontSize: 12)),
    ]);
  }

  Widget _previewGuide() {
    final now = DateTime.now(), start = _windowStart;
    final end = start.add(const Duration(hours: 2));
    final rows = _visibleIndices;
    const surface = Color(0xFF242A36), focus = Color(0xFF90CAF9);
    return Row(children: [
      SizedBox(width: 150, child: ListView.builder(itemCount: _groups.length, itemBuilder: (_, i) {
        final selected = i == _groupIndex;
        return Container(height: 44, margin: const EdgeInsets.all(2), padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(color: selected && _groupFocus ? focus : selected ? const Color(0xFF344D70) : surface,
            borderRadius: BorderRadius.circular(7)),
          alignment: Alignment.centerLeft, child: Text(_groups[i], maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: selected && _groupFocus ? Colors.black : Colors.white, fontSize: 13)));
      })),
      const SizedBox(width: 10),
      Expanded(child: LayoutBuilder(builder: (_, constraints) {
        const channelWidth = 165.0;
        final width = (constraints.maxWidth - channelWidth).clamp(1.0, 10000.0).toDouble();
        double x(DateTime d) => (d.difference(start).inSeconds / 7200 * width).clamp(0.0, width).toDouble();
        return Column(children: [
          SizedBox(height: 25, child: Row(children: [
            const SizedBox(width: channelWidth, child: Text('Canales', style: TextStyle(color: Colors.white70))),
            for (var i = 0; i < 4; i++) SizedBox(width: width / 4, child: Text(_clock(start.add(Duration(minutes: 30 * i))), style: const TextStyle(color: Colors.white70))),
          ])),
          Expanded(child: rows.isEmpty ? const Center(child: Text('No hay canales en este grupo', style: TextStyle(color: Colors.white))) :
            ListView.builder(controller: _previewScroll, itemExtent: 54, itemCount: rows.length, itemBuilder: (_, row) {
              final i = rows[row], channel = widget.channels[i];
              final focused = !_groupFocus && i == _highlightIndex;
              final programmes = _programmes(i);
              final channelFocused = focused && (_programmeIndex < 0 || programmes.isEmpty);
              return Row(children: [
                Container(width: channelWidth, margin: const EdgeInsets.symmetric(vertical: 2), padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: channelFocused ? focus : surface, borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    SizedBox(width: 32, height: 28, child: channel.logo.isEmpty ? Icon(Icons.tv, color: channelFocused ? Colors.black : Colors.white) : Image.network(channel.logo, fit: BoxFit.contain, errorBuilder: (_, _, _) => Icon(Icons.tv, color: channelFocused ? Colors.black : Colors.white))),
                    const SizedBox(width: 7),
                    Expanded(child: Text(channel.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: channelFocused ? Colors.black : Colors.white, fontSize: 13))),
                    if (_tuned && i == _channelIndex) Icon(Icons.play_arrow, color: channelFocused ? Colors.black : Colors.white, size: 15),
                    if (widget.isFavorite(channel)) const Icon(Icons.star, color: Colors.amber, size: 14),
                  ])),
                SizedBox(width: width, child: Stack(fit: StackFit.expand, children: [
                  if (programmes.isEmpty) Container(margin: const EdgeInsets.all(2), alignment: Alignment.centerLeft, padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(6)), child: const Text('Sin programación', style: TextStyle(color: Colors.white70))),
                  for (var j = 0; j < programmes.length; j++)
                    if (x(programmes[j].stop) - x(programmes[j].start) > 3) Positioned(left: x(programmes[j].start), width: x(programmes[j].stop) - x(programmes[j].start), top: 2, bottom: 2,
                      child: Container(margin: const EdgeInsets.symmetric(horizontal: 2), padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(color: focused && _programmeIndex == j ? focus : (!now.isBefore(programmes[j].start) && now.isBefore(programmes[j].stop) ? const Color(0xFF344D70) : surface),
                          border: Border.all(color: const Color(0xFF485467)), borderRadius: BorderRadius.circular(6)),
                        child: Align(alignment: Alignment.centerLeft, child: Text(programmes[j].title, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: focused && _programmeIndex == j ? Colors.black : Colors.white, fontSize: 12))))),
                  if (!now.isBefore(start) && now.isBefore(end)) Positioned(left: x(now), top: 0, bottom: 0, child: IgnorePointer(child: Container(width: 2, color: Colors.orange))),
                ])),
              ]);
            })),
        ]);
      })),
    ]);
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
            final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
            if (_groupFocus) { _selectGroup(_groupIndex + delta); } else { _moveRow(delta); }
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) { unawaited(_confirmGuide()); return KeyEventResult.handled; }
          if (key == LogicalKeyboardKey.arrowRight) {
            setState(() {
              if (_groupFocus) { if (_visibleIndices.isNotEmpty) _groupFocus = false; }
              else { final entries = _programmes(_highlightIndex); if (_programmeIndex + 1 < entries.length) { _programmeIndex++; } else { _timeShift++; final shifted = _programmes(_highlightIndex); _programmeIndex = shifted.isEmpty ? -1 : 0; } }
            });
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowLeft) {
            setState(() {
              if (_programmeIndex >= 0) { _programmeIndex--; }
              else if (!_groupFocus) { _groupFocus = true; }
              else if (_timeShift > 0) { _timeShift--; }
            });
            return KeyEventResult.handled;
          }
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
            final rows = _visibleIndices;
            if (rows.isNotEmpty) { final pos = rows.indexOf(_channelIndex); unawaited(_switchChannel(rows[(pos + delta + rows.length) % rows.length])); }
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
        if (_preview) const Positioned(left: 0, right: 0, top: 0, height: 16, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview) const Positioned(left: 0, right: 308, top: 16, height: 162, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview) const Positioned(right: 0, width: 20, top: 16, height: 162, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview) const Positioned(left: 0, right: 0, top: 178, bottom: 0, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview && !_tuned) const Positioned(right: 20, width: 288, top: 16, height: 162, child: ColoredBox(color: Color(0xFF242A36), child: Center(child: Text('Selecciona un canal', style: TextStyle(color: Colors.white70))))),
        if (_preview) Positioned(left: 20, right: 340, top: 20, height: 150, child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: _previewDetails())),
        if (_preview) Positioned(left: 20, right: 20, top: 184, bottom: 20, child: _previewGuide()),
        if (_player != null) Positioned(
          key: const ValueKey('vision-iptv-video'),
          top: _preview ? 16 : 0, right: _preview ? 20 : 0,
          left: _preview ? null : 0, bottom: _preview ? null : 0,
          width: _preview ? 288 : null, height: _preview ? 162 : null,
          child: Video(player: _player!)),
        if (_tuned && !_ready && !_failed) Positioned(
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

