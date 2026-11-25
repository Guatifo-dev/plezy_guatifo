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
  const _Programme(this.title, this.start, this.stop, this.description, {this.poster = ''});
  final String poster;
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

class _GuideData {
  const _GuideData(this.programmes, this.names);
  final Map<String, List<_Programme>> programmes;
  final Map<String, String> names;
}

_GuideData _parseGuide(List<int> bytes) {
  final raw = bytes.length > 1 && bytes[0] == 31 && bytes[1] == 139 ? gzip.decode(bytes) : bytes;
  final doc = XmlDocument.parse(utf8.decode(raw, allowMalformed: true));
  final result = <String, List<_Programme>>{};
  final names = <String, String>{};
  for (final c in doc.findAllElements('channel')) {
    final id = c.getAttribute('id');
    if (id == null) continue;
    final labels = c.findElements('display-name');
    names[id] = labels.isEmpty ? id : labels.first.innerText;
    result[id] = [];
  }
  final now = DateTime.now();
  for (final p in doc.findAllElements('programme')) {
    final id = p.getAttribute('channel');
    final start = _xmltvDate(p.getAttribute('start'));
    final stop = _xmltvDate(p.getAttribute('stop'));
    if (id == null || start == null || stop == null || stop.isBefore(now.subtract(const Duration(days: 1))) || start.isAfter(now.add(const Duration(days: 3)))) continue;
    final titles = p.findElements('title');
    final descriptions = p.findElements('desc');
    final icons = p.findElements('icon');
    final poster = icons.isEmpty ? '' : icons.first.getAttribute('src') ?? '';
    names.putIfAbsent(id, () => id);
    (result[id] ??= []).add(_Programme(titles.isEmpty ? '' : titles.first.innerText, start, stop, descriptions.isEmpty ? '' : descriptions.first.innerText, poster: poster));
  }
  for (final entries in result.values) {
    entries.sort((a, b) => a.start.compareTo(b.start));
  }
  return _GuideData(result, names);
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
  const VisionIptvScreen({super.key, this.settingsOnly = false, this.onExit});
  final VoidCallback? onExit;
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
  List<String> _recent = [];
  Map<String, String> _epgNames = {}, _epgOverrides = {};
  int _bannerSeconds = 4;


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
      _lastChannel = prefs.getString('vision_iptv_last_fullscreen');
      _recent = prefs.getStringList('vision_iptv_recent') ?? [];
      _bannerSeconds = prefs.getInt('vision_iptv_banner_seconds') ?? 4;
      try { _epgOverrides = Map<String, String>.from(jsonDecode(prefs.getString('vision_iptv_epg_overrides') ?? '{}') as Map); } catch (_) {}
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

  String? _lastChannel;
  bool _guideOpen = false;
  bool _openWhenLoaded = false;
  Future<void> _openUnifiedGuide() async {
    if (!mounted || _guideOpen || _channels.isEmpty) return;
    _guideOpen = true;
    _openWhenLoaded = false;
    try {
      final index = _channels.indexWhere((c) => c.favoriteId == _lastChannel);
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => _IptvPlayer(startFullscreen: index >= 0, channel: index >= 0 ? _channels[index] : _channels.first, channels: List.unmodifiable(_channels),
          guide: _guide, guideSource: _guideNotifier, allChannels: List.unmodifiable(_channels),
          onFavorite: _toggleFavorite, isFavorite: (c) => _favorites.contains(c.favoriteId), onFullscreen: (c) async { _lastChannel = c.favoriteId; final prefs = await SharedPreferences.getInstance(); await prefs.setString('vision_iptv_last_fullscreen', c.favoriteId); },
          recent: () => List.unmodifiable(_recent), onTuned: (c) async { _recent = [c.favoriteId, ..._recent.where((id) => id != c.favoriteId)].take(30).toList(); final prefs = await SharedPreferences.getInstance(); await prefs.setStringList('vision_iptv_recent', _recent); },
          onRefreshGuide: () => _loadGuide(force: true), guideStatus: () => _epgStatus,
          bannerSeconds: _bannerSeconds, epgNames: () => _epgNames, epgId: (c) => _epgOverrides[c.favoriteId] ?? c.tvgId,
          onAssignEpg: (c, id) async { if (id == null) { _epgOverrides.remove(c.favoriteId); } else { _epgOverrides[c.favoriteId] = id; } final prefs = await SharedPreferences.getInstance(); await prefs.setString('vision_iptv_epg_overrides', jsonEncode(_epgOverrides)); },
          useExoPlayer: _useExoPlayer, tunneling: _tunneling, buffer: _buffer, forceHls: _forceHls)));
    } finally {
      _guideOpen = false;
      if (mounted) unawaited(_restore());
      if (mounted) { if (widget.onExit != null) { widget.onExit!(); } else { _entry.requestFocus(); } }
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
          if (mounted) { setState(() { _guide = cached.programmes; _epgNames = cached.names; _epgStatus = 'Guía disponible'; }); _guideNotifier.value = cached.programmes; }
          if (!force && age < const Duration(hours: 6)) return;
        } catch (_) {}
      }
      final response = await http.get(uri).timeout(const Duration(seconds: 45));
      if (response.statusCode != 200) throw StateError('EPG HTTP');
      final parsed = await compute(_parseGuide, response.bodyBytes);
      await cache.writeAsBytes(response.bodyBytes, flush: true);
      await prefs.setString('vision_epg_cache_source', url);
      if (mounted) { setState(() { _guide = parsed.programmes; _epgNames = parsed.names; _epgStatus = 'Guía actualizada'; }); _guideNotifier.value = parsed.programmes; }
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
      _openWhenLoaded = true;
      if (_channels.isEmpty) { _openWhenLoaded = true; }
      else { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _openWhenLoaded) unawaited(_openUnifiedGuide()); }); }
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
        if (_openWhenLoaded) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _openWhenLoaded) unawaited(_openUnifiedGuide()); });
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
      if (_channels.isEmpty) Text('TV en directo · IPTV', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 14),
      if (_loading) const CircularProgressIndicator(),
      if (_error != null) Text(_error!),
      if (_channels.isNotEmpty)
        Focus(focusNode: _entry, autofocus: true, onFocusChange: (focused) { if (focused && !_guideOpen && _openWhenLoaded) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) unawaited(_openUnifiedGuide()); }); }, onKeyEvent: (_, event) { if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.enter)) { unawaited(_openUnifiedGuide()); return KeyEventResult.handled; } return KeyEventResult.ignored; }, child: const SizedBox.shrink())
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
  const _IptvPlayer({required this.startFullscreen, required this.onFullscreen, required this.bannerSeconds, required this.epgNames, required this.epgId, required this.onAssignEpg, required this.recent, required this.onTuned, required this.onRefreshGuide, required this.guideStatus, required this.channel, required this.channels, required this.guide, required this.guideSource, required this.allChannels, required this.onFavorite, required this.isFavorite, required this.useExoPlayer, required this.tunneling, required this.buffer, required this.forceHls});
  final bool startFullscreen;
  final Future<void> Function(_Channel) onFullscreen;
  final int bannerSeconds;
  final Map<String, String> Function() epgNames;
  final String Function(_Channel) epgId;
  final Future<void> Function(_Channel, String?) onAssignEpg;
  final List<String> Function() recent;
  final Future<void> Function(_Channel) onTuned;
  final Future<void> Function() onRefreshGuide;
  final String Function() guideStatus;
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
  bool _menuOpen = false, _recentOnly = false, _refreshingGuide = false;
  bool _settingsOpen = false, _settingsDirty = false;
  late int _bannerSeconds = widget.bannerSeconds;
  Timer? _okHold;
  bool _okLong = false, _fastScroll = false;
  static const _bannerChoices = [2, 3, 4, 5, 7, 10, 15, 0];
  int _settingsIndex = 0;
  String _settingsUrl = '', _settingsEpg = '', _settingsBuffer = 'minimum';
  bool _settingsExo = true, _settingsHls = false, _settingsTunnel = false;
  final _settingsScroll = ScrollController();
  int _menuIndex = 0;
  String _menuStatus = '';
  static const _menuLabels = ['Guía de televisión', 'Favoritos', 'Últimos canales', 'Actualizar programación', 'Ajustes IPTV', 'Salir de IPTV'];
  static const _menuIcons = [Icons.calendar_today, Icons.star_border, Icons.history, Icons.refresh, Icons.settings, Icons.exit_to_app];
  bool _inProgrammes = true;
  Timer? _leftHold, _backHold;
  bool _leftLong = false, _backLong = false;
  bool _exiting = false;
  final _videoKey = GlobalKey();
  Future<void> _resizeVideo() async {
    if (!mounted || _player == null || _closing != null) return;
    final box = _videoKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final pos = box.localToGlobal(Offset.zero);
    try {
      final player = _player!;
      if (player is PlayerAndroid) {
        await const MethodChannel('com.plezy/exo_player').invokeMethod('setIptvBounds', {'left': _preview ? (pos.dx*dpr).round() : 0, 'top': _preview ? (pos.dy*dpr).round() : 0, 'width': _preview ? (box.size.width*dpr).round() : 0, 'height': _preview ? (box.size.height*dpr).round() : 0});
      } else {
        await const MethodChannel('com.plezy/mpv_player').invokeMethod('setIptvBounds', {'left': _preview ? (pos.dx*dpr).round() : 0, 'top': _preview ? (pos.dy*dpr).round() : 0, 'width': _preview ? (box.size.width*dpr).round() : 0, 'height': _preview ? (box.size.height*dpr).round() : 0});
      }
    } catch (e) { debugPrint('[VisionIPTV] resize failed: ${e.runtimeType}'); }
  }
  void _scheduleResize() => WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) unawaited(_resizeVideo()); });
  _Programme? get _selectedProgramme {
    final entries = _programmes(_highlightIndex);
    return _programmeIndex >= 0 && _programmeIndex < entries.length ? entries[_programmeIndex] : null;
  }
  bool get _onCurrentProgramme {
    final p = _selectedProgramme;
    final now = DateTime.now();
    return p == null ? _timeShift == 0 : !now.isBefore(p.start) && now.isBefore(p.stop);
  }
  void _resetGuideToNow() {
    setState(() {
      _timeShift = 0;
      _menuOpen = false;
      _groupFocus = false;
      _inProgrammes = true;
      if (_tuned) {
        _highlightIndex = _channelIndex;
        if (!_visibleIndices.contains(_channelIndex)) { _recentOnly = false; _groupIndex = 0; }
      }
      _programmeIndex = -1;
      _stepProgramme(0);
    });
    _scrollPreview();
  }
  void _backShort() {
    if (!_preview) { _previewMode(true); return; }
    if (_settingsOpen) { _closeSettings(); return; }
    if (_menuOpen) { _closeMenu(); return; }
    if (_groupFocus || _timeShift != 0 || !_onCurrentProgramme) { _resetGuideToNow(); return; }
    if (_tuned) { _previewMode(false); } else { unawaited(_confirmGuide()); }
  }
  Future<void> _exitIptv() async {
    if (_exiting || !mounted) return;
    setState(() => _exiting = true);
    await _close();
    if (mounted) Navigator.of(context).pop();
  }
  void _stepProgramme(int delta) {
    final entries = _guide[widget.epgId(widget.channels[_highlightIndex])] ?? const <_Programme>[];
    if (entries.isEmpty) return;
    final visible = _programmes(_highlightIndex);
    final selected = _programmeIndex >= 0 && _programmeIndex < visible.length ? visible[_programmeIndex] : null;
    var index = selected == null ? entries.indexWhere((p) => p.stop.isAfter(DateTime.now())) : entries.indexOf(selected) + delta;
    if (selected == null && delta < 0) index--;
    if (index < 0 || index >= entries.length) return;
    final target = entries[index];
    final start = _windowStart;
    if (!target.stop.isAfter(start) || !target.start.isBefore(start.add(const Duration(hours: 2)))) {
      final now = DateTime.now();
      final base = DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30);
      _timeShift = (target.start.difference(base).inSeconds / 1800).floor();
    }
    _programmeIndex = _programmes(_highlightIndex).indexOf(target);
  }
  Map<String, List<_Programme>> get _guide => widget.guideSource.value;
  List<String> get _groups => ['Todos', 'Favoritos', ...widget.channels.map((c) => c.group).toSet()];
  List<int> get _visibleIndices {
    if (_recentOnly) {
      final indices = {for (var i = 0; i < widget.channels.length; i++) widget.channels[i].favoriteId: i};
      return [for (final id in widget.recent()) if (indices.containsKey(id)) indices[id]!];
    }
    return [for (var i = 0; i < widget.channels.length; i++) if (_groupIndex == 0 || (_groupIndex == 1 ? widget.isFavorite(widget.channels[i]) : widget.channels[i].group == _groups[_groupIndex])) i];
  }

  void _closeMenu() {
    setState(() { _menuOpen = false; _groupFocus = true; });
    _scrollGroup();
    _playerFocus.requestFocus();
  }

  void _scrollGroup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_groupScroll.hasClients) return;
      final p = _groupScroll.position;
      _groupScroll.jumpTo((_groupIndex * 48.0 - p.viewportDimension / 2 + 24).clamp(0.0, p.maxScrollExtent).toDouble());
    });
  }

  Future<void> _activateMenu() async {
    switch (_menuIndex) {
      case 0:
      case 1:
      case 2:
        setState(() {
          _recentOnly = _menuIndex == 2;
          _groupIndex = _menuIndex == 1 ? 1 : 0;
          _menuOpen = false;
          _groupFocus = false;
          _timeShift = 0;
          final rows = _visibleIndices;
          if (rows.isNotEmpty) _highlightIndex = rows.contains(_channelIndex) ? _channelIndex : rows.first;
          _programmeIndex = -1;
          _stepProgramme(0);
        });
        _scrollPreview();
        break;
      case 3:
        if (_refreshingGuide) return;
        setState(() { _refreshingGuide = true; _menuStatus = 'Actualizando…'; });
        try {
          await widget.onRefreshGuide();
          if (mounted) setState(() => _menuStatus = widget.guideStatus());
        } catch (_) {
          if (mounted) setState(() => _menuStatus = 'No se pudo actualizar la guía');
        } finally {
          if (mounted) setState(() => _refreshingGuide = false);
        }
        break;
      case 4:
        await _openSettings();
        break;
      case 5:
        await _exitIptv();
        break;
    }
  }

  Future<void> _openSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || !_menuOpen || _exiting) return;
    setState(() {
      _settingsUrl = prefs.getString('vision_iptv_url') ?? '';
      _settingsEpg = prefs.getString('vision_iptv_epg') ?? '';
      _settingsExo = prefs.getBool('vision_iptv_exo') ?? true;
      _settingsHls = prefs.getBool('vision_iptv_force_hls') ?? false;
      _settingsTunnel = prefs.getBool('vision_iptv_tunneling') ?? false;
      _settingsBuffer = prefs.getString('vision_iptv_buffer') ?? 'minimum';
      _settingsIndex = 0;
      _settingsOpen = true;
    });
  }

  void _closeSettings() {
    setState(() { _settingsOpen = false; if (_settingsDirty) _menuStatus = 'Ajustes guardados. Se aplicarán al volver a entrar en IPTV.'; });
    _playerFocus.requestFocus();
  }

  List<String> get _settingKeys => ['m3u', 'epg', 'lists', 'banner', 'player', if (_settingsExo) ...['format', 'tunnel'] else 'buffer', 'refresh', 'back'];

  Future<void> _manageLists() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    List<Map<String, String>> lists = [];
    try { lists = (jsonDecode(prefs.getString('vision_iptv_lists') ?? '[]') as List).map((v) => Map<String, String>.from(v as Map)).toList(); } catch (_) {}
    if (_settingsUrl.isNotEmpty && !lists.any((v) => v['url'] == _settingsUrl)) {
      lists.insert(0, {'name': 'Lista actual', 'url': _settingsUrl, 'epg': _settingsEpg});
    }
    while (mounted) {
      final action = await showDialog<int>(context: context, barrierColor: Colors.black26, builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF242A36), title: const Text('Listas IPTV'),
        content: SizedBox(width: 420, height: 260, child: ListView(children: [
          ListTile(autofocus: true, leading: const Icon(Icons.add), title: const Text('Añadir nueva lista'), onTap: () => Navigator.pop(ctx, -1)),
          for (var i = 0; i < lists.length; i++) ListTile(title: Text(lists[i]['name'] ?? 'Lista'), trailing: lists[i]['url'] == _settingsUrl ? const Icon(Icons.check) : null, onTap: () => Navigator.pop(ctx, i)),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
      ));
      if (!mounted || action == null) break;
      final existing = action >= 0 ? lists[action] : <String, String>{};
      final name = TextEditingController(text: existing['name'] ?? '');
      final url = TextEditingController(text: existing['url'] ?? '');
      final epg = TextEditingController(text: existing['epg'] ?? '');
      final choice = await showDialog<String>(context: context, barrierColor: Colors.black26, builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF242A36), title: Text(action < 0 ? 'Nueva lista IPTV' : 'Editar lista IPTV'),
        content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre')),
          TextField(controller: url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'URL M3U')),
          TextField(controller: epg, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'URL EPG (opcional)')),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          if (action >= 0 && existing['url'] != _settingsUrl) TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Eliminar')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Guardar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'activate'), child: const Text('Guardar y activar')),
        ],
      ));
      final item = {'name': name.text.trim().isEmpty ? 'Lista IPTV' : name.text.trim(), 'url': url.text.trim(), 'epg': epg.text.trim()};
      name.dispose(); url.dispose(); epg.dispose();
      if (!mounted) return;
      if (choice == null) continue;
      if (choice == 'delete') { lists.removeAt(action); }
      else {
        final uri = Uri.tryParse(item['url']!);
        if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) { setState(() => _menuStatus = 'URL M3U no válida'); continue; }
        if (action < 0) { lists.add(item); } else { lists[action] = item; }
        if (choice == 'activate' || existing['url'] == _settingsUrl) {
          await prefs.setString('vision_iptv_url', item['url']!);
          await prefs.setString('vision_iptv_epg', item['epg']!);
          if (mounted) setState(() { _settingsUrl = item['url']!; _settingsEpg = item['epg']!; _settingsDirty = true; });
        }
      }
      await prefs.setString('vision_iptv_lists', jsonEncode(lists));
    }
    if (mounted) { _playerFocus.requestFocus(); _scheduleResize(); }
  }

  Future<void> _editSettingsUrl(bool epg) async {
    final controller = TextEditingController(text: epg ? _settingsEpg : _settingsUrl);
    final result = await showDialog<String>(context: context, barrierColor: Colors.black26, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF242A36),
      title: Text(epg ? 'URL EPG (XMLTV)' : 'Lista IPTV M3U'),
      content: TextField(controller: controller, autofocus: true, keyboardType: TextInputType.url,
        decoration: InputDecoration(hintText: epg ? 'Vacío: detección automática' : 'URL de la lista'),
        onSubmitted: (v) => Navigator.pop(ctx, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Guardar')),
      ],
    ));
    controller.dispose();
    if (!mounted) return;
    if (result != null) {
      final value = result.trim();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(epg ? 'vision_iptv_epg' : 'vision_iptv_url', value);
      if (mounted) setState(() { if (epg) { _settingsEpg = value; } else { _settingsUrl = value; } _settingsDirty = true; });
    }
    if (mounted) { _playerFocus.requestFocus(); _scheduleResize(); }
  }

  Future<void> _activateSetting() async {
    final key = _settingKeys[_settingsIndex];
    if (key == 'back') { _closeSettings(); return; }
    if (key == 'lists') { await _manageLists(); return; }
    if (key == 'banner') { final prefs = await SharedPreferences.getInstance(); if (!mounted) return; setState(() => _bannerSeconds = _bannerChoices[(_bannerChoices.indexOf(_bannerSeconds) + 1) % _bannerChoices.length]); await prefs.setInt('vision_iptv_banner_seconds', _bannerSeconds); return; }
    if (key == 'm3u' || key == 'epg') { await _editSettingsUrl(key == 'epg'); return; }
    if (key == 'refresh') {
      if (_refreshingGuide) return;
      setState(() { _refreshingGuide = true; _menuStatus = 'Actualizando…'; });
      try {
        await widget.onRefreshGuide();
        if (mounted) setState(() => _menuStatus = widget.guideStatus());
      } catch (_) {
        if (mounted) setState(() => _menuStatus = 'No se pudo actualizar la guía');
      } finally {
        if (mounted) setState(() => _refreshingGuide = false);
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || !_settingsOpen) return;
    setState(() {
      _settingsDirty = true;
      switch (key) {
        case 'player': _settingsExo = !_settingsExo; break;
        case 'format': _settingsHls = !_settingsHls; break;
        case 'tunnel': _settingsTunnel = !_settingsTunnel; break;
        case 'buffer': _settingsBuffer = _settingsBuffer == 'minimum' ? 'small' : _settingsBuffer == 'small' ? 'normal' : 'minimum'; break;
      }
      _settingsIndex = _settingsIndex.clamp(0, _settingKeys.length - 1).toInt();
    });
    switch (key) {
      case 'player': await prefs.setBool('vision_iptv_exo', _settingsExo); break;
      case 'format': await prefs.setBool('vision_iptv_force_hls', _settingsHls); break;
      case 'tunnel': await prefs.setBool('vision_iptv_tunneling', _settingsTunnel); break;
      case 'buffer': await prefs.setString('vision_iptv_buffer', _settingsBuffer); break;
    }
  }

  void _moveSetting(int delta) {
    setState(() => _settingsIndex = (_settingsIndex + delta).clamp(0, _settingKeys.length - 1).toInt());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_settingsScroll.hasClients) return;
      final p = _settingsScroll.position;
      _settingsScroll.jumpTo((_settingsIndex * 44.0 - p.viewportDimension / 2 + 22).clamp(0.0, p.maxScrollExtent).toDouble());
    });
  }

  Widget _iptvSettingsPanel() {
    final labels = <String, String>{'m3u': 'Lista M3U activa', 'epg': 'URL EPG', 'lists': 'Listas IPTV', 'banner': 'Duración barra de información', 'player': 'Reproductor IPTV', 'format': 'Formato', 'tunnel': 'Tunneling', 'buffer': 'Búfer MPV', 'refresh': 'Actualizar programación', 'back': 'Volver al menú'};
    final values = <String, String>{'m3u': _settingsUrl.isEmpty ? 'Sin configurar' : 'Configurada', 'epg': _settingsEpg.isEmpty ? 'Automática desde M3U' : 'Manual', 'lists': 'Gestionar', 'banner': _bannerSeconds == 0 ? 'Permanente' : '${_bannerSeconds} s', 'player': _settingsExo ? 'ExoPlayer' : 'MPV', 'format': _settingsHls ? 'HLS' : 'Auto', 'tunnel': _settingsTunnel ? 'Sí' : 'No', 'buffer': _settingsBuffer == 'minimum' ? 'Mínimo (0)' : _settingsBuffer == 'small' ? 'Pequeño' : 'Normal', 'refresh': _refreshingGuide ? 'Actualizando…' : '', 'back': ''};
    final icons = <String, IconData>{'m3u': Icons.list, 'epg': Icons.calendar_today, 'lists': Icons.playlist_add, 'banner': Icons.timer, 'player': Icons.play_circle_outline, 'format': Icons.video_settings, 'tunnel': Icons.settings_ethernet, 'buffer': Icons.memory, 'refresh': Icons.refresh, 'back': Icons.arrow_back};
    final keys = _settingKeys;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF1B202A), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Ajustes IPTV', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Expanded(child: ListView.builder(controller: _settingsScroll, itemExtent: 44, itemCount: keys.length, itemBuilder: (_, i) {
          final key = keys[i], focused = i == _settingsIndex;
          final fg = focused ? Colors.black : Colors.white;
          return Container(margin: const EdgeInsets.only(bottom: 4), padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: focused ? const Color(0xFF90CAF9) : const Color(0xFF242A36), borderRadius: BorderRadius.circular(7)),
            child: Row(children: [
              Icon(icons[key], size: 19, color: fg),
              const SizedBox(width: 10),
              Expanded(child: Text(labels[key]!, style: TextStyle(color: fg, fontSize: 14))),
              Text(values[key]!, style: TextStyle(color: focused ? Colors.black87 : Colors.white70, fontSize: 13)),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: fg, size: 18),
            ]));
        })),
        const SizedBox(height: 4),
        Text(_settingsDirty ? 'Cambios guardados · se aplicarán al volver a entrar en IPTV' : 'OK: cambiar · Atrás: volver al menú', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        if (_menuStatus.isNotEmpty) Text(_menuStatus, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
    );
  }

  Widget _iptvMenu() {
    return Container(width: 224, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: const Color(0xFF1B202A), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.all(8), child: Text('IPTV', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
        Expanded(child: ListView.builder(itemCount: _menuLabels.length, itemBuilder: (_, i) {
          final focused = !_settingsOpen && i == _menuIndex;
          final foreground = focused ? Colors.black : Colors.white;
          return Container(height: 36, margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(color: focused ? const Color(0xFF90CAF9) : Colors.transparent, borderRadius: BorderRadius.circular(7)),
            child: Row(children: [
              Icon(_menuIcons[i], size: 19, color: foreground),
              const SizedBox(width: 9),
              Expanded(child: Text(_menuLabels[i], maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: foreground, fontSize: 13))),
            ]));
        })),
        if (_menuStatus.isNotEmpty) Padding(padding: const EdgeInsets.all(6), child: Text(_menuStatus, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11))),
      ]));
  }
  DateTime get _windowStart {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30).add(Duration(minutes: 30 * _timeShift));
  }
  List<_Programme> _programmes(int index) {
    final start = _windowStart, end = start.add(const Duration(hours: 2));
    return (_guide[widget.epgId(widget.channels[index])] ?? const <_Programme>[]).where((p) => p.start.isBefore(end) && p.stop.isAfter(start)).toList();
  }
  void _guideChanged() { if (mounted) setState(() { if (_preview && _programmeIndex < 0 && !_groupFocus) _stepProgramme(0); }); }
  void _selectGroup(int index) {
    setState(() { _recentOnly = false; _groupIndex = index.clamp(0, _groups.length - 1).toInt(); final rows = _visibleIndices; if (rows.isNotEmpty) _highlightIndex = rows.first; _programmeIndex = -1; });
    _scrollPreview();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _groupScroll.hasClients) { final p = _groupScroll.position; _groupScroll.jumpTo((_groupIndex * 48.0 - p.viewportDimension / 2 + 24).clamp(0.0, p.maxScrollExtent).toDouble()); } });
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
    if (_groupFocus) { if (_visibleIndices.isNotEmpty) setState(() { _groupFocus = false; _programmeIndex = -1; _stepProgramme(0); }); return; }
    if (_visibleIndices.isEmpty || _switching) return;
    if (!_tuned) {
      setState(() { _channelIndex = _highlightIndex; _tuned = true; _switching = true; });
      await _start();
    } else if (_highlightIndex == _channelIndex && !_failed) { _previewMode(false); }
    else { await _switchChannel(_highlightIndex); }
  }
  final _playerFocus = FocusNode();
  final _previewScroll = ScrollController();
  final _groupScroll = ScrollController();
  Timer? _clockTimer;
  bool _technicalVisible = false;
  _Programme? get _currentProgramme {
    final now = DateTime.now();
    for (final p in _guide[widget.epgId(_channel)] ?? const <_Programme>[]) {
      if (!now.isBefore(p.start) && now.isBefore(p.stop)) return p;
    }
    return null;
  }
  _Programme? get _nextProgramme {
    final now = DateTime.now();
    for (final p in _guide[widget.epgId(_channel)] ?? const <_Programme>[]) {
      if (p.start.isAfter(now)) return p;
    }
    return null;
  }
  String _clock(DateTime date) {
    final d = date.toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  void _previewMode(bool value) {
    setState(() { _preview = value; _menuOpen = false; _showChannels = false; _highlightIndex = _channelIndex; _programmeIndex = -1; _inProgrammes = true; _timeShift = 0; _groupFocus = false; _showName = true; if (!_visibleIndices.contains(_channelIndex)) { _recentOnly = false; _groupIndex = 0; } if (value) _stepProgramme(0); });
    _scheduleResize();
    if (value) {
      _timer?.cancel();
      _scrollPreview();
    } else { unawaited(widget.onFullscreen(_channel)); _hideLater(); }
    _playerFocus.requestFocus();
  }
  void _scrollPreview() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_preview || !_previewScroll.hasClients) return;
      final p = _previewScroll.position;
      _previewScroll.jumpTo((_visibleIndices.indexOf(_highlightIndex) * 54.0 - p.viewportDimension / 2 + 27).clamp(0.0, p.maxScrollExtent).toDouble());
    });
  }
  Future<void> _channelContext() async {
    if (_visibleIndices.isEmpty) return;
    final c = widget.channels[_highlightIndex];
    final action = await showDialog<String>(context: context, barrierColor: Colors.black26, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF242A36), title: Text(c.name),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(autofocus: true, leading: const Icon(Icons.calendar_today), title: const Text('Asignar EPG'), onTap: () => Navigator.pop(ctx, 'epg')),
        ListTile(leading: const Icon(Icons.star_border), title: Text(widget.isFavorite(c) ? 'Quitar de favoritos' : 'Añadir a favoritos'), onTap: () => Navigator.pop(ctx, 'favorite')),
      ]),
    ));
    if (!mounted) return;
    if (action == 'favorite') { await widget.onFavorite(c); if (mounted) setState(() {}); }
    if (action == 'epg') await _assignEpg(c);
    if (mounted) { _playerFocus.requestFocus(); _scheduleResize(); }
  }

  Future<void> _assignEpg(_Channel c) async {
    final names = widget.epgNames();
    final ids = names.keys.toList()..sort((a,b) => (names[a] ?? a).toLowerCase().compareTo((names[b] ?? b).toLowerCase()));
    String search = '';
    final selected = await showDialog<String>(context: context, barrierColor: Colors.black26, builder: (ctx) => StatefulBuilder(builder: (ctx, update) {
      final filtered = ids.where((id) => '${names[id]} $id'.toLowerCase().contains(search.toLowerCase())).toList();
      return AlertDialog(backgroundColor: const Color(0xFF242A36), title: Text('Asignar EPG · ${c.name}'),
        content: SizedBox(width: 480, height: 270, child: Column(children: [
          TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar canal EPG'), onChanged: (v) => update(() => search = v)),
          Expanded(child: filtered.isEmpty ? const Center(child: Text('No hay canales EPG disponibles')) : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
            final id = filtered[i];
            return ListTile(autofocus: i == 0, title: Text(names[id] ?? id), subtitle: Text(id), trailing: id == widget.epgId(c) ? const Icon(Icons.check) : null, onTap: () => Navigator.pop(ctx, id));
          })),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')), TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Restablecer automática'))],
      );
    }));
    if (!mounted || selected == null) return;
    await widget.onAssignEpg(c, selected.isEmpty ? null : selected);
    if (mounted) setState(() { _programmeIndex = -1; _stepProgramme(0); });
  }

  Future<void> _options() async {
    final selected = _preview || _showChannels ? widget.channels[_highlightIndex] : _channel;
    final action = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text(selected.name), actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, 'favorite'), child: Text(widget.isFavorite(selected) ? 'Quitar de favoritos' : 'Añadir a favoritos')),
        TextButton(onPressed: () => Navigator.pop(ctx, 'technical'), child: const Text('Información técnica')),
        TextButton(onPressed: () => Navigator.pop(ctx, 'exit'), child: const Text('Salir de IPTV')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
      ]));
    if (!mounted) return;
    if (action == 'exit') { await _exitIptv(); return; }
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
    _preview = !widget.startFullscreen;
    _tuned = widget.startFullscreen;
    _switching = _tuned;
    widget.guideSource.addListener(_guideChanged);
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) { if (mounted && _preview) setState(() {}); });
    if (_preview) _stepProgramme(0);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) { _scrollPreview(); if (_tuned) unawaited(_start()); } });
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
          final firstFrame = !_ready;
          setState(() { _ready = true; _failed = false; });
          if (firstFrame) unawaited(widget.onTuned(_channel));
          _scheduleResize();
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
      if (mounted) { _scheduleResize(); if (!_preview) unawaited(widget.onFullscreen(_channel)); _hideLater(); }
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
    if (_bannerSeconds == 0) return;
    _timer = Timer(Duration(seconds: _bannerSeconds), () {
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
    _leftHold?.cancel(); _backHold?.cancel();
    _clockTimer?.cancel();
    _groupScroll.dispose();
    _settingsScroll.dispose();
    _okHold?.cancel();
    _previewScroll.dispose();
    _playerFocus.dispose();
    unawaited(_close());
    super.dispose();
  }

  String _dateLabel(DateTime d) {
    const days = ['lun.', 'mar.', 'mié.', 'jue.', 'vie.', 'sáb.', 'dom.'];
    const months = ['ene.', 'feb.', 'mar.', 'abr.', 'may.', 'jun.', 'jul.', 'ago.', 'sep.', 'oct.', 'nov.', 'dic.'];
    final local = d.toLocal();
    return '${days[local.weekday - 1]}, ${local.day} ${months[local.month - 1]}';
  }
  String _slotLabel(DateTime d) => d.hour == 0 && d.minute == 0 ? '${_dateLabel(d)}  ${_clock(d)}' : _clock(d);

  Widget _previewDetails() {
    final channel = widget.channels[_highlightIndex];
    final now = DateTime.now();
    _Programme? p = _selectedProgramme;
    if (p == null) { for (final entry in _guide[widget.epgId(channel)] ?? const <_Programme>[]) { if (!now.isBefore(entry.start) && now.isBefore(entry.stop)) { p = entry; break; } } }
    final live = p != null && !now.isBefore(p.start) && now.isBefore(p.stop);
    final progress = p == null ? 0.0 : (now.difference(p.start).inSeconds / p.stop.difference(p.start).inSeconds.clamp(1, 9999999)).clamp(0.0, 1.0).toDouble();
    final poster = p?.poster ?? '';
    final details = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(p?.title ?? channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
        if (widget.isFavorite(channel)) const Icon(Icons.star, color: Colors.amber, size: 20),
      ]),
      const SizedBox(height: 5),
      Row(children: [
        if (p != null) Text('${_clock(p.start)} – ${_clock(p.stop)}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
        if (live) ...[
          const SizedBox(width: 10),
          SizedBox(width: 45, child: LinearProgressIndicator(value: progress, color: const Color(0xFF90CAF9), backgroundColor: Colors.white24)),
          const SizedBox(width: 8),
          Text('${p!.stop.difference(now).inMinutes} min', style: const TextStyle(color: Colors.white70)),
        ],
        const Spacer(),
        Flexible(child: Text(channel.group, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12))),
      ]),
      const SizedBox(height: 7),
      Expanded(child: Text(p?.description ?? '', maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 14))),
    ]);
    if (poster.isEmpty || _fastScroll || !poster.startsWith('http')) return details;
    return Row(children: [Expanded(child: details), const SizedBox(width: 12), SizedBox(width: 92, height: 138, child: ClipRRect(borderRadius: BorderRadius.circular(9), child: Image.network(poster, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink())))]);
  }

  Widget _previewGuide() {
    final now = DateTime.now(), start = _windowStart;
    final end = start.add(const Duration(hours: 2));
    final rows = _visibleIndices;
    const surface = Color(0xFF242A36), focus = Color(0xFF90CAF9);
    if (_settingsOpen) return Row(children: [
      _iptvMenu(),
      const SizedBox(width: 12),
      Expanded(child: _iptvSettingsPanel()),
    ]);
    if (_menuOpen) return Row(children: [
      _iptvMenu(),
      const SizedBox(width: 12),
      Expanded(child: _guideGrid(rows, now, start, end, surface, focus)),
    ]);
    return Row(children: [
      if (_groupFocus) SizedBox(width: 150, child: ListView.builder(controller: _groupScroll, itemCount: _groups.length, itemBuilder: (_, i) {
        final selected = i == _groupIndex;
        return Container(height: 44, margin: const EdgeInsets.all(2), padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(color: selected && _groupFocus ? focus : selected ? const Color(0xFF344D70) : surface,
            borderRadius: BorderRadius.circular(7)),
          alignment: Alignment.centerLeft, child: Text(_groups[i], maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: selected && _groupFocus ? Colors.black : Colors.white, fontSize: 13)));
      })),
      if (_groupFocus) const SizedBox(width: 10),
      Expanded(child: _guideGrid(rows, now, start, end, surface, focus)),
    ]);
  }

  Widget _guideGrid(List<int> rows, DateTime now, DateTime start, DateTime end, Color surface, Color focus) {
    return LayoutBuilder(builder: (_, constraints) {
        const channelWidth = 235.0;
        final width = (constraints.maxWidth - channelWidth).clamp(1.0, 10000.0).toDouble();
        double x(DateTime d) => (d.difference(start).inSeconds / 7200 * width).clamp(0.0, width).toDouble();
        return Column(children: [
          SizedBox(height: 25, child: Row(children: [
            SizedBox(width: channelWidth, child: Text('${_dateLabel(now)} ${_clock(now)}', style: const TextStyle(color: Color(0xFF90CAF9), fontWeight: FontWeight.bold))),
            for (var i = 0; i < 4; i++) SizedBox(width: width / 4, child: Text(_slotLabel(start.add(Duration(minutes: 30 * i))), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70))),
          ])),
          Expanded(child: rows.isEmpty ? const Center(child: Text('No hay canales en este grupo', style: TextStyle(color: Colors.white))) :
            ListView.builder(controller: _previewScroll, itemExtent: 54, itemCount: rows.length, itemBuilder: (_, row) {
              final i = rows[row], channel = widget.channels[i];
              final focused = !_menuOpen && !_groupFocus && i == _highlightIndex;
              final programmes = _programmes(i);
              final channelFocused = focused;
              return Row(children: [
                Container(width: channelWidth, margin: const EdgeInsets.symmetric(vertical: 2), padding: const EdgeInsets.all(6),
                  
                  child: Row(children: [
                    SizedBox(width: 28, child: Text('${i + 1}', style: TextStyle(color: channelFocused ? focus : (_tuned && i == _channelIndex ? focus : Colors.white70)))),
                    SizedBox(width: 42, height: 30, child: channel.logo.isEmpty ? Icon(Icons.tv, color: channelFocused ? focus : Colors.white) : Image.network(channel.logo, fit: BoxFit.contain, errorBuilder: (_, _, _) => Icon(Icons.tv, color: channelFocused ? focus : Colors.white))),
                    const SizedBox(width: 7),
                    Expanded(child: Text(channel.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: channelFocused ? focus : Colors.white, fontSize: 13))),
                    if (_tuned && i == _channelIndex) Icon(Icons.play_arrow, color: channelFocused ? focus : focus, size: 15),
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
                  if (!now.isBefore(start) && now.isBefore(end)) Positioned(left: x(now), top: 0, bottom: 0, child: IgnorePointer(child: Container(width: 2, color: focus.withAlpha(160)))),
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
      if (current != null && current.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(current.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14))),
      if (next != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('A continuación · ${_clock(next.start)} · ${next.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70))),
      if (_technicalVisible && _technical.isNotEmpty) Text(_technical, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    ]));
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _exiting,
    onPopInvokedWithResult: (didPop, _) { if (!didPop && !_exiting && _backHold == null) _backShort(); },
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(focusNode: _playerFocus, autofocus: true, onKeyEvent: (_, event) {
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) {
          if (event is KeyDownEvent) { _backLong = false; _backHold?.cancel(); _backHold = Timer(const Duration(milliseconds: 650), () { _backLong = true; unawaited(_exitIptv()); }); }
          if (event is KeyUpEvent) { _backHold?.cancel(); _backHold = null; if (!_backLong) _backShort(); }
          return KeyEventResult.handled;
        }
        if (_preview && _settingsOpen) {
          if (event is! KeyDownEvent) return KeyEventResult.handled;
          if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) { _moveSetting(key == LogicalKeyboardKey.arrowDown ? 1 : -1); }
          else if (key == LogicalKeyboardKey.arrowLeft) { _closeSettings(); }
          else if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) { unawaited(_activateSetting()); }
          return KeyEventResult.handled;
        }
        if (_preview && _menuOpen) {
          if (event is! KeyDownEvent) return KeyEventResult.handled;
          if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
            setState(() => _menuIndex = (_menuIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(0, _menuLabels.length - 1).toInt());
          } else if (key == LogicalKeyboardKey.arrowRight) { _closeMenu(); }
          else if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) { unawaited(_activateMenu()); }
          return KeyEventResult.handled;
        }
        if (_preview && key == LogicalKeyboardKey.arrowLeft) {
          if (event is KeyDownEvent) { _leftLong = false; _leftHold?.cancel(); _leftHold = Timer(const Duration(milliseconds: 600), () { if (mounted) setState(() { _leftLong = true; if (!_groupFocus) { _inProgrammes = true; _stepProgramme(-1); } }); }); }
          if (event is KeyUpEvent) { _leftHold?.cancel(); _leftHold = null; if (!_leftLong) { if (_groupFocus) { setState(() { _menuOpen = true; _menuStatus = ''; }); } else if (_onCurrentProgramme) { setState(() => _groupFocus = true); _scrollGroup(); } else { setState(() => _stepProgramme(-1)); } } }
          return KeyEventResult.handled;
        }
        if (_preview && !_groupFocus && (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter)) {
          if (event is KeyDownEvent) { _okLong = false; _okHold?.cancel(); _okHold = Timer(const Duration(milliseconds: 600), () { if (mounted) { _okLong = true; unawaited(_channelContext()); } }); }
          if (event is KeyUpEvent) { _okHold?.cancel(); _okHold = null; if (!_okLong) unawaited(_confirmGuide()); }
          return KeyEventResult.handled;
        }
        if (_preview && !_groupFocus && (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown)) {
          if (event is KeyDownEvent || event is KeyRepeatEvent) { if (event is KeyRepeatEvent && !_fastScroll) setState(() => _fastScroll = true); _moveRow(key == LogicalKeyboardKey.arrowDown ? 1 : -1); }
          if (event is KeyUpEvent && _fastScroll) setState(() => _fastScroll = false);
          return KeyEventResult.handled;
        }
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
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
              if (_groupFocus) { if (_visibleIndices.isNotEmpty) { _groupFocus = false; _inProgrammes = true; _programmeIndex = -1; _stepProgramme(0); } }
              else { _inProgrammes = true; _stepProgramme(1); }
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
          setState(() { _technicalVisible = false; _showName = _bannerSeconds == 0 ? !_showName : true; });
          _hideLater();
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
        if (_preview) const Positioned(right: 0, left: 308, top: 16, height: 162, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview) const Positioned(left: 0, width: 20, top: 16, height: 162, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview) const Positioned(left: 0, right: 0, top: 178, bottom: 0, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview && !_tuned) const Positioned(left: 20, width: 288, top: 16, height: 162, child: ColoredBox(color: Color(0xFF242A36), child: Center(child: Text('Selecciona un canal', style: TextStyle(color: Colors.white70))))),
        if (_preview) Positioned(left: 328, right: 20, top: 20, height: 150, child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: _previewDetails())),
        if (_preview) Positioned(left: 20, right: 20, top: 184, bottom: 20, child: _previewGuide()),
        if (_player != null) Positioned(
          key: const ValueKey('vision-iptv-video'),
          top: _preview ? 16 : 0, right: _preview ? null : 0,
          left: _preview ? 20 : 0, bottom: _preview ? null : 0,
          width: _preview ? 288 : null, height: _preview ? 162 : null,
          child: SizedBox(key: _videoKey, child: Video(player: _player!))),
        if (_preview) const Positioned(left: 20, top: 16, width: 288, height: 162, child: IgnorePointer(child: CustomPaint(painter: _PreviewCornerMask()))),
        if (_tuned && !_ready && !_failed) Positioned(
          top: _preview ? 70 : 0, right: _preview ? null : 0,
          left: _preview ? 140 : 0, bottom: _preview ? null : 0,
          child: const Center(child: CircularProgressIndicator())),
        if (_failed) Positioned(top: _preview ? 70 : 0, right: _preview ? null : 0,
          left: _preview ? 20 : 0, bottom: _preview ? null : 0,
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


class _PreviewCornerMask extends CustomPainter {
  const _PreviewCornerMask();
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final outside = Path()..addRect(bounds);
    final inside = Path()..addRRect(RRect.fromRectAndRadius(bounds, const Radius.circular(12)));
    canvas.drawPath(Path.combine(PathOperation.difference, outside, inside), Paint()..color = const Color(0xFF10151D));
  }
  @override
  bool shouldRepaint(covariant _PreviewCornerMask oldDelegate) => false;
}
