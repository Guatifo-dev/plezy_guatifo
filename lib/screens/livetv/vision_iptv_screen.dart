import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3, OpenMode;
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
import 'package:crypto/crypto.dart';
import '../video_player/player_output_format.dart';
import 'package:provider/provider.dart';
import 'live_tv_screen.dart';
import '../../widgets/plex_trailer_preview.dart';
import '../video_player/wakelock_controller.dart';

Future<void> _showIptvRemoteHelp(BuildContext context) async {
  await showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (_) => const _IptvRemoteHelp(),
  );
}

class _IptvRemoteHelp extends StatefulWidget {
  const _IptvRemoteHelp();
  @override
  State<_IptvRemoteHelp> createState() => _IptvRemoteHelpState();
}

class _IptvRemoteHelpState extends State<_IptvRemoteHelp> {
  static const _pages = <(String, IconData, List<(String, String)>)>[
    ('Pantalla completa', Icons.tv, [
      ('↑ / ↓', 'Siguiente / anterior canal del grupo actual.'),
      ('OK', 'Mostrar la barra de información del canal.'),
      ('←', 'Abrir la EPG por columnas si la barra está oculta.'),
      ('→', 'Volver al último canal si la barra está oculta.'),
      ('← / →', 'Con la barra visible: programa anterior / siguiente.'),
      ('MENU', 'Abrir opciones del canal.'),
      ('Atrás', 'Ocultar la barra; con la barra oculta, abrir la EPG clásica.'),
      ('Atrás largo', 'Salir de TV en vivo (650 ms).'),
    ]),
    ('EPG clásica', Icons.calendar_today, [
      ('↑ / ↓', 'Recorrer canales o grupos, según el foco. Mantener para avanzar rápidamente.'),
      ('← / →', 'Recorrer programas; desde el programa actual, izquierda vuelve al canal, grupos y menú.'),
      ('← largo', 'Retroceder al programa anterior (600 ms).'),
      ('OK', 'Sintonizar en vista previa; si ya está sintonizado, ampliar a pantalla completa.'),
      ('OK / programa', 'Si está en emisión, sintonizar o ampliar; si es pasado o futuro, abrir su menú.'),
      ('MENU / OK largo', 'Abrir el menú del canal o programa (OK largo: 600 ms).'),
      ('Atrás', 'Regresar a la hora actual si se consultan otros programas o grupos; después, pantalla completa.'),
    ]),
    ('EPG por columnas', Icons.view_column, [
      ('← / →', 'Mover el foco entre menú, grupos, canales, programas y sinopsis.'),
      ('↑ / ↓', 'Recorrer los elementos de la columna activa; en sinopsis, desplazar el texto.'),
      ('OK', 'Abrir menú o grupo; sintonizar canal en vista previa o ampliar si ya está sintonizado.'),
      ('OK / programa', 'En emisión: sintonizar o ampliar. Pasado o futuro: abrir menú del programa.'),
      ('MENU / OK largo', 'Abrir menú contextual del canal o programa (600 ms).'),
      ('Atrás', 'Volver a pantalla completa.'),
    ]),
    ('Información del programa', Icons.info_outline, [
      ('← / →', 'Consultar el programa anterior o siguiente.'),
      ('↑ / ↓', 'Desplazar la sinopsis.'),
      ('Atrás / OK', 'Volver a la guía en el último programa consultado.'),
    ]),
    ('Menús contextuales', Icons.list, [
      ('↑ / ↓', 'Seleccionar una opción.'),
      ('OK', 'Confirmar la opción seleccionada.'),
      ('Atrás', 'Cerrar el menú sin elegir una opción.'),
      ('OK largo', 'Al abrir un menú, soltar OK antes de volver a pulsarlo.'),
    ]),
    ('Menú principal IPTV', Icons.menu, [
      ('↑ / ↓', 'Recorrer guía, favoritos, últimos canales, actualización, ajustes y salida.'),
      ('OK', 'Abrir la opción seleccionada.'),
      ('→', 'Regresar a la guía o pasar a la columna de grupos.'),
      ('Atrás', 'Cerrar el menú en la EPG clásica; en columnas, volver al vídeo.'),
    ]),
    ('Ajustes IPTV', Icons.settings, [
      ('↑ / ↓', 'Recorrer secciones y opciones.'),
      ('OK', 'Abrir una sección o cambiar la opción seleccionada.'),
      ('← / Atrás', 'Volver al nivel anterior de ajustes.'),
      ('Inactividad', 'Los ajustes y formularios no se cierran automáticamente.'),
    ]),
  ];
  int _page = -1;
  int _selected = 0;
  final _scroll = ScrollController();
  final _focus = FocusNode();
  void _changePage(int page) {
    setState(() => _page = page);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }
  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF90CAF9);
    final detail = _page >= 0;
    return Dialog(
      backgroundColor: const Color(0xFF1B202A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 30, vertical: 24),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (_, event) {
          final key = event.logicalKey;
          if (event is KeyUpEvent) return KeyEventResult.handled;
          if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) {
            if (event is KeyDownEvent) {
              if (detail) { _changePage(-1); } else { Navigator.of(context).pop(); }
            }
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
            final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
            if (detail) {
              if (_scroll.hasClients) {
                _scroll.jumpTo((_scroll.offset + delta * 55).clamp(0.0, _scroll.position.maxScrollExtent).toDouble());
              }
            } else {
              setState(() => _selected = (_selected + delta).clamp(0, _pages.length - 1).toInt());
              if (_scroll.hasClients) {
                _scroll.jumpTo((_selected * 46.0 - _scroll.position.viewportDimension / 2 + 23).clamp(0.0, _scroll.position.maxScrollExtent).toDouble());
              }
            }
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent) {
            if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.arrowRight) {
              if (!detail) _changePage(_selected);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft && detail) {
              _changePage(-1);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.handled;
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 470),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Guía de uso del mando', style: TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(detail ? _pages[_page].$1 : 'Selecciona una pantalla para consultar sus controles.', style: const TextStyle(color: blue, fontSize: 16)),
              const Divider(color: Colors.white24),
              Expanded(child: detail
                ? ListView.separated(
                    controller: _scroll,
                    itemCount: _pages[_page].$3.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 12),
                    itemBuilder: (_, i) {
                      final item = _pages[_page].$3[i];
                      return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                        Container(
                          width: 124,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                          decoration: BoxDecoration(color: const Color(0xFF303B4D), borderRadius: BorderRadius.circular(6)),
                          child: Text(item.$1, textAlign: TextAlign.center, style: const TextStyle(color: blue, fontSize: 14, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(child: Text(item.$2, style: const TextStyle(color: Colors.white, fontSize: 15))),
                      ]);
                    })
                : ListView.builder(
                    controller: _scroll,
                    itemExtent: 46,
                    itemCount: _pages.length,
                    itemBuilder: (_, i) {
                      final focused = i == _selected;
                      final fg = focused ? Colors.black : Colors.white;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(color: focused ? blue : const Color(0xFF242A36), borderRadius: BorderRadius.circular(7)),
                        child: Row(children: [
                          Icon(_pages[i].$2, color: fg, size: 20),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_pages[i].$1, style: TextStyle(color: fg, fontSize: 15))),
                          Icon(Icons.chevron_right, color: fg),
                        ]),
                      );
                    })),
              const Divider(color: Colors.white24),
              const Text('Tras 60 s sin usar el mando, las pantallas de consulta vuelven al vídeo si hay un canal sintonizado. Los ajustes están excluidos.', style: TextStyle(color: blue, fontSize: 12)),
              const SizedBox(height: 8),
              Text(detail ? '↑ / ↓: desplazar · ← / Atrás: volver al tutorial' : '↑ / ↓: seleccionar · OK: abrir · Atrás: cerrar', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Channel {
  _Channel(this.name, this.group, this.url, this.logo, {this.drmType, this.drmLicense, this.manifestType, this.tvgId = '', this.source = '', this.sourceName = '', this.epgSource = ''});
  final String name, group, url, logo;
  final String? drmType, drmLicense, manifestType;
  final String tvgId, source, sourceName, epgSource;
  late final String legacyId = jsonEncode([group, name, tvgId]);
  late final String favoriteId = jsonEncode([source, group, name, tvgId]);
  Map<String,dynamic> toResumeJson() => {'name':name,'group':group,'url':url,'logo':logo,'drm':drmType,'license':drmLicense,'manifest':manifestType,'tvg':tvgId,'source':source,'sourceName':sourceName,'epg':epgSource};
  static _Channel? fromResumeJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = Map<String,dynamic>.from(jsonDecode(raw) as Map);
      final uri = Uri.tryParse(m['url'] as String? ?? '');
      if (uri == null || !['http','https'].contains(uri.scheme) || uri.host.isEmpty) return null;
      return _Channel(m['name'] as String,m['group'] as String,uri.toString(),m['logo'] as String? ?? '',
        drmType:m['drm'] as String?,drmLicense:m['license'] as String?,manifestType:m['manifest'] as String?,
        tvgId:m['tvg'] as String? ?? '',source:m['source'] as String? ?? '',sourceName:m['sourceName'] as String? ?? '',epgSource:m['epg'] as String? ?? '');
    } catch (_) { return null; }
  }
  _Channel withSource(String id, String label, String epg) => _Channel(name, group, url, logo, drmType: drmType, drmLicense: drmLicense, manifestType: manifestType, tvgId: tvgId, source: id, sourceName: label, epgSource: epg);
}

Future<void> _writePlaylistSnapshot((String, List<_Channel>, String, int) input) async {
  final db = sqlite3.open(input.$1);
  try {
    db.execute('CREATE TABLE metadata(epg TEXT, vod INTEGER)');
    db.execute('CREATE TABLE channels(name TEXT, grp TEXT, url TEXT, logo TEXT, drm TEXT, license TEXT, manifest TEXT, tvg TEXT)');
    db.execute('INSERT INTO metadata VALUES (?,?)', [input.$3,input.$4]);
    final insert = db.prepare('INSERT INTO channels VALUES (?,?,?,?,?,?,?,?)');
    try {
      db.execute('BEGIN');
      for (final c in input.$2) { insert.execute([c.name,c.group,c.url,c.logo,c.drmType,c.drmLicense,c.manifestType,c.tvgId]); }
      db.execute('COMMIT');
      db.execute('CREATE INDEX channel_group ON channels(grp)');
    } finally { insert.dispose(); }
  } finally { db.dispose(); }
}

class _PlaylistSnapshot {
  _PlaylistSnapshot(this.channels,this.epg,this.vod,this.total,this.groups);
  final List<_Channel> channels;
  final String epg;
  final int vod,total;
  final List<String> groups;
}
_PlaylistSnapshot _readPlaylistSnapshot((String,String,Set<String>,Set<String>) input) {
  final db = sqlite3.open(input.$1, mode: OpenMode.readOnly);
  try {
    final meta = db.select('SELECT epg,vod FROM metadata').first;
    final groups = [for (final row in db.select('SELECT DISTINCT grp FROM channels ORDER BY grp COLLATE NOCASE')) row['grp'] as String];
    final total = db.select('SELECT COUNT(*) AS n FROM channels').first['n'] as int;
    final channels = <(int,_Channel)>[];
    final query = db.prepare('SELECT rowid AS seq,* FROM channels WHERE grp=? ORDER BY rowid');
    try {
      for (final group in groups) {
        // Hidden groups are not loaded at all, except previously favourited channels.
        if (input.$3.contains(group) && input.$4.isEmpty) continue;
        for (final row in query.select([group])) {
          if (input.$3.contains(group) && !input.$4.contains(jsonEncode([input.$2,group,row['name'],row['tvg']]))) continue;
          channels.add((row['seq'] as int,_Channel(row['name'] as String,group,row['url'] as String,row['logo'] as String,
            drmType: row['drm'] as String?,drmLicense: row['license'] as String?,manifestType: row['manifest'] as String?,tvgId: row['tvg'] as String)));
        }
      }
    } finally { query.dispose(); }
    if (channels.isEmpty && total > 0) {
      final row = db.select('SELECT rowid AS seq,* FROM channels ORDER BY rowid LIMIT 1').first;
      channels.add((row['seq'] as int,_Channel(row['name'] as String,row['grp'] as String,row['url'] as String,row['logo'] as String,drmType: row['drm'] as String?,drmLicense: row['license'] as String?,manifestType: row['manifest'] as String?,tvgId: row['tvg'] as String)));
    }
    channels.sort((a,b) => a.$1.compareTo(b.$1));
    return _PlaylistSnapshot(channels.map((c) => c.$2).toList(),meta['epg'] as String,meta['vod'] as int,total,groups);
  } finally { db.dispose(); }
}

Future<(List<_Channel>, String, int)> _decodePlaylist((String, String, bool) input) async {
  final base = Uri.parse(input.$2);
  String autoEpg = '';
  int excluded = 0;
  bool vod = false;
  final attr = RegExp(r'(?:^|\s)(?:tvg-type|stream-type|type)="?(vod|movie|series|video)"?(?:\s|,|$)', caseSensitive: false);
  final vodGroup = RegExp(r'^(?:VOD|MOVIES|PELICULAS|PELÍCULAS|SERIES|FILMS)(?:\s*[:|/–-]|\s*$)', caseSensitive: false);
  final vodPath = RegExp(r'/(?:movie|series|vod)/', caseSensitive: false);
  final vodFile = RegExp(r'\.(?:mp4|mkv|avi|mov|m4v|webm)$', caseSensitive: false);
  final tvgIdPattern = RegExp(r'tvg-id="([^"]*)"');
  final groupPattern = RegExp(r'group-title="([^"]*)"');
  final logoPattern = RegExp(r'tvg-logo="([^"]*)"');
  final headerPattern = RegExp(r'(?:x-tvg-url|url-tvg|tvg-url)="([^"]+)"', caseSensitive: false);
  final channels = <_Channel>[];
  String? name;
  String group = 'Otros', logo = '', tvgId = '';
  String? drmType, drmLicense, manifestType;
  await for (final raw in File(input.$1).openRead().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
    final line = raw.trim();
    if (line.startsWith('#EXTM3U')) {
      final auto = headerPattern.firstMatch(line)?.group(1);
      if (auto != null) autoEpg = base.resolve(auto.split(',').first.trim()).toString();
    } else if (line.startsWith('#EXTINF:')) {
      drmType = null;
      drmLicense = null;
      manifestType = null;
      tvgId = tvgIdPattern.firstMatch(line)?.group(1) ?? '';
      final comma = line.indexOf(',');
      name = comma < 0 ? 'Canal' : line.substring(comma + 1).trim();
      group = groupPattern.firstMatch(line)?.group(1) ?? 'Otros';
      logo = logoPattern.firstMatch(line)?.group(1) ?? '';
      vod = attr.hasMatch(line) || (tvgId.isEmpty && group.trim().toUpperCase().startsWith('VOD') && vodGroup.hasMatch(group.trim()));
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
      if (input.$3 && (vod || vodPath.hasMatch(uri.path) || vodFile.hasMatch(uri.path))) { excluded++; }
      else if (uri.scheme == 'http' || uri.scheme == 'https') {
        channels.add(_Channel(name, group.isEmpty ? 'Otros' : group, uri.toString(), logo,
          drmType: drmType, drmLicense: drmLicense, manifestType: manifestType, tvgId: tvgId));
      }
      name = null;
      drmType = null;
      drmLicense = null;
      manifestType = null;
    }
  }
  return (channels, autoEpg, excluded);
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
  const _GuideData(this.programmes, this.names, this.logos);
  final Map<String, String> logos;
  final Map<String, List<_Programme>> programmes;
  final Map<String, String> names;
}

// Import one XML element at a time into a disk-backed index. Never build a
// document tree or retain the whole decompressed XMLTV in the Dart heap.
Future<int> _indexGuide((String, String) input) async {
  final file = File(input.$1);
  final db = sqlite3.open(input.$2);
  try {
    db.execute('CREATE TABLE channels(id TEXT PRIMARY KEY, name TEXT NOT NULL, logo TEXT NOT NULL)');
    db.execute('CREATE TABLE programmes(channel TEXT, start INTEGER, stop INTEGER, title TEXT, description TEXT, poster TEXT)');
    final channel = db.prepare('INSERT OR REPLACE INTO channels VALUES (?, ?, ?)');
    final programme = db.prepare('INSERT INTO programmes VALUES (?, ?, ?, ?, ?, ?)');
    final now = DateTime.now();
    final earliest = now.subtract(const Duration(days: 1));
    final latest = now.add(const Duration(days: 3));
    int count = 0;
    try {
      final signature = await file.openRead(0, 2).expand((x) => x).toList();
      Stream<List<int>> bytes = file.openRead();
      if (signature.length == 2 && signature[0] == 31 && signature[1] == 139) bytes = gzip.decoder.bind(bytes);
      db.execute('BEGIN');
      await for (final nodes in bytes.transform(const Utf8Decoder(allowMalformed: true))
          .toXmlEvents().selectSubtreeEvents((event) => event.name == 'channel' || event.name == 'programme').toXmlNodes()) {
        for (final node in nodes.whereType<XmlElement>()) {
          if (node.name.local == 'channel') {
            final id = node.getAttribute('id');
            if (id == null) continue;
            channel.execute([id, node.getElement('display-name')?.innerText ?? id, node.getElement('icon')?.getAttribute('src') ?? '']);
          } else if (node.name.local == 'programme') {
            final id = node.getAttribute('channel');
            final start = _xmltvDate(node.getAttribute('start')), stop = _xmltvDate(node.getAttribute('stop'));
            if (id == null || start == null || stop == null || stop.isBefore(earliest) || start.isAfter(latest)) continue;
            programme.execute([id, start.millisecondsSinceEpoch, stop.millisecondsSinceEpoch,
              node.getElement('title')?.innerText ?? '', node.getElement('desc')?.innerText ?? '',
              node.getElement('icon')?.getAttribute('src') ?? '']);
            count++;
          }
        }
      }
      db.execute('COMMIT');
      db.execute('CREATE INDEX programme_channel_start ON programmes(channel, start)');
      db.execute("INSERT OR IGNORE INTO channels SELECT DISTINCT channel, channel, '' FROM programmes");
      return count;
    } finally {
      channel.dispose(); programme.dispose();
    }
  } finally { db.dispose(); }
}

_GuideData _readIndexedGuide((String, List<String>, bool) input) {
  final db = sqlite3.open(input.$1, mode: OpenMode.readOnly);
  try {
    final names = <String, String>{if (input.$3) for (final row in db.select('SELECT id,name FROM channels ORDER BY name COLLATE NOCASE')) row['id'] as String: row['name'] as String};
    final logos = <String, String>{if (input.$3) for (final row in db.select("SELECT id,logo FROM channels WHERE logo <> ''")) row['id'] as String: row['logo'] as String};
    final result = <String, List<_Programme>>{};
    final query = db.prepare('SELECT start,stop,title,description,poster FROM programmes WHERE channel=? ORDER BY start');
    try {
      for (final id in input.$2.toSet()) {
        if (id.isEmpty) continue;
        result[id] = [for (final p in query.select([id])) _Programme(p['title'] as String,
          DateTime.fromMillisecondsSinceEpoch(p['start'] as int, isUtc: true),
          DateTime.fromMillisecondsSinceEpoch(p['stop'] as int, isUtc: true), p['description'] as String, poster: p['poster'] as String)];
      }
    } finally { query.dispose(); }
    return _GuideData(result, names, logos);
  } finally { db.dispose(); }
}

String _epgKey(String source, String id) => jsonEncode([source, id]);
String _sourceId(String url) => sha256.convert(utf8.encode(url)).toString();
Set<String> _hiddenGroups(Map<String,String> list) {
  try { return (jsonDecode(list['hiddenGroups'] ?? '[]') as List).whereType<String>().toSet(); } catch (_) { return {}; }
}

class _ListStatus {
  const _ListStatus(this.state, {this.channels = 0, this.groups = 0, this.vod = 0, this.updated, this.detail = ''});
  final String state, detail;
  final int channels, groups, vod;
  final DateTime? updated;
  String get label => state == 'Cargada' ? '$channels canales · $groups grupos' : detail.isEmpty ? state : '$state · $detail';
}
bool _isXtream(Map<String,String> list) => list['type'] == 'xc';
bool _excludeVod(Map<String,String> list) => list['excludeVod'] != 'false';
String _playlistKey(Map<String,String> list) => _sourceId(jsonEncode([list['url'], list['type'] ?? 'm3u', list['user'] ?? '', list['password'] ?? '', _excludeVod(list)]));
Uri _xcEndpoint(Uri base, String endpoint, Map<String,String> query) => base.replace(
  path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/$endpoint', queryParameters: query, fragment: '');
Uri _xcStream(Uri base, String kind, String user, String password, String id, String ext) => base.replace(
  pathSegments: [...base.pathSegments.where((p) => p.isNotEmpty), kind, user, password, '$id.$ext'], query: null, fragment: '');
class _XtreamError implements Exception {
  const _XtreamError(this.message);
  final String message;
}
Future<(List<_Channel>, String, int)> _fetchXtream(http.Client client, Uri base, Map<String,String> list, void Function() processing) async {
  final user = list['user'] ?? '', password = list['password'] ?? '';
  if (user.isEmpty || password.isEmpty) throw const _XtreamError('Faltan usuario o contraseña');
  final credentials = {'username': user, 'password': password};
  Future<dynamic> request([String? action]) async {
    final uri = _xcEndpoint(base, 'player_api.php', {...credentials, if (action != null) 'action': action});
    final response = await client.get(uri).timeout(const Duration(seconds: 120));
    if (response.statusCode != 200) throw _PlaylistHttpError(response.statusCode);
    return compute(_decodeXtreamJson, response.bodyBytes);
  }
  final account = await request();
  if (account is! Map || account['user_info'] is! Map || account['user_info']['auth'].toString() != '1') {
    throw const _XtreamError('Autenticación rechazada');
  }
  final categories = await request('get_live_categories');
  final streams = await request('get_live_streams');
  if (streams is! List) throw const _XtreamError('Respuesta de canales no válida');
  processing();
  final groups = <String,String>{};
  if (categories is List) {
    for (final c in categories) {
      if (c is Map) groups[c['category_id'].toString()] = (c['category_name'] ?? 'Otros').toString();
    }
  }
  final channels = <_Channel>[];
  final formats = account['user_info']['allowed_output_formats'];
  final ext = formats is List && !formats.contains('ts') && formats.contains('m3u8') ? 'm3u8' : 'ts';
  for (final c in streams) {
    if (c is! Map || c['stream_id'] == null) continue;
    final id = c['stream_id'].toString();
    if (id.isEmpty) continue;
    channels.add(_Channel((c['name'] ?? 'Canal').toString(), groups[c['category_id'].toString()] ?? 'Otros',
      _xcStream(base, 'live', user, password, id, ext).toString(), (c['stream_icon'] ?? '').toString(),
      tvgId: (c['epg_channel_id'] ?? '').toString()));
  }
  // IPTV is a live-TV interface. Never fetch film/series catalogues through Xtream.
  final epg = _xcEndpoint(base, 'xmltv.php', credentials).toString();
  return (channels, epg, 0);
}
dynamic _decodeXtreamJson(List<int> bytes) => jsonDecode(utf8.decode(bytes, allowMalformed: true));
Future<void> _downloadPlaylistSnapshot((Map<String,String>,String,String) input) async {
  final (list,pending,temp) = input;
  final uri = Uri.parse(list['url'] ?? '');
  final client = http.Client();
  try {
    final (List<_Channel>,String,int) parsed;
    if (_isXtream(list)) {
      parsed = await _fetchXtream(client,uri,list,(){});
    } else {
      final response = await client.send(http.Request('GET',uri)).timeout(const Duration(seconds:120));
      if (response.statusCode != 200) throw _PlaylistHttpError(response.statusCode);
      await response.stream.timeout(const Duration(seconds:120)).pipe(File(temp).openWrite()).timeout(const Duration(seconds:120));
      parsed = await _decodePlaylist((temp,uri.toString(),_excludeVod(list)));
    }
    if (parsed.$1.isEmpty) throw const FormatException('Sin canales en directo');
    await _writePlaylistSnapshot((pending,parsed.$1,parsed.$2,parsed.$3));
  } finally {
    client.close();
    try { final file = File(temp); if (await file.exists()) await file.delete(); } catch (_) {}
  }
}
const _listRefreshChoices = [0,6,12,24,48,168];
const _epgRefreshChoices = [0,1,3,6,12,24];
int _refreshHours(SharedPreferences prefs,bool epg) {
  final choices = epg ? _epgRefreshChoices : _listRefreshChoices;
  final value = prefs.getInt(epg?'vision_iptv_epg_refresh_hours':'vision_iptv_list_refresh_hours') ?? (epg?6:24);
  return choices.contains(value)?value:(epg?6:24);
}
String _refreshLabel(int hours) => hours==0?'Nunca':hours==168?'7 días':hours==1?'1 hora':'$hours horas';

class _PlaylistHttpError implements Exception {
  const _PlaylistHttpError(this.status);
  final int status;
}

List<Map<String, String>> _iptvLists(SharedPreferences prefs) {
  final legacy = prefs.getString('vision_iptv_url') ?? '';
  List<Map<String, String>> lists = [];
  try { lists = (jsonDecode(prefs.getString('vision_iptv_lists') ?? '[]') as List).map((v) => Map<String, String>.from(v as Map)).toList(); } catch (_) {}
  if (legacy.isNotEmpty && !lists.any((v) => v['url'] == legacy)) lists.insert(0, {'name': 'Lista actual', 'url': legacy, 'epg': prefs.getString('vision_iptv_epg') ?? ''});
  for (final list in lists) { list['active'] ??= list['url'] == legacy ? 'true' : 'false'; list['id'] ??= _sourceId(list['url'] ?? ''); }
  return lists;
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

// Discover reads only the five recent channel IDs from the local indexed lists.
class VisionDiscoverChannel {
  const VisionDiscoverChannel(this._channel, this.name, this.logo, this.programme, this.description, this.schedule);
  final _Channel _channel;
  final String name, logo, programme, description, schedule;
  String get id => _channel.favoriteId;
}

final visionDiscoverIptvChanged = ValueNotifier<int>(0);
const _discoverIptvPref = 'vision_iptv_discover_row';
Future<bool> visionDiscoverIptvEnabled() async =>
    (await SharedPreferences.getInstance()).getBool(_discoverIptvPref) ?? true;

List<_Channel> _readDiscoverRecent((String, String, String, String, List<String>) input) {
  final db = sqlite3.open(input.$1, mode: OpenMode.readOnly);
  try {
    final result = <_Channel>[];
    final query = db.prepare('SELECT * FROM channels WHERE grp=? AND name=? AND tvg=? LIMIT 1');
    try {
      for (final id in input.$5) {
        final parts = jsonDecode(id) as List;
        if (parts.length != 4 || parts[0] != input.$2) continue;
        for (final row in query.select([parts[1], parts[2], parts[3]])) {
          result.add(_Channel(row['name'] as String, row['grp'] as String, row['url'] as String, row['logo'] as String,
            drmType: row['drm'] as String?, drmLicense: row['license'] as String?, manifestType: row['manifest'] as String?, tvgId: row['tvg'] as String)
            .withSource(input.$2, input.$3, input.$4));
        }
      }
    } finally { query.dispose(); }
    return result;
  } finally { db.dispose(); }
}

Future<List<VisionDiscoverChannel>> loadVisionDiscoverChannels() async {
  final prefs = await SharedPreferences.getInstance();
  if (!(prefs.getBool(_discoverIptvPref) ?? true)) return [];
  final ids = (prefs.getStringList('vision_iptv_recent') ?? []).take(5).toList();
  final resume = _Channel.fromResumeJson(prefs.getString('vision_iptv_resume_channel'));
  if (ids.isEmpty && resume != null) ids.add(resume.favoriteId);
  if (ids.isEmpty) return [];
  final support = await getApplicationSupportDirectory();
  final cache = await getApplicationCacheDirectory();
  final found = <String, _Channel>{};
  final active = _iptvLists(prefs).where((l) => l['active'] == 'true').toList();
  for (final list in active) {
    final id = list['id']!;
    final disk = File('${support.path}/vision_playlist_${_playlistKey(list)}.sqlite');
    if (!await disk.exists()) continue;
    try {
      var epg = list['epg'] ?? '';
      if (epg.isEmpty) epg = prefs.getString('vision_iptv_default_epg') ?? prefs.getString('vision_iptv_epg') ?? '';
      if (epg.isEmpty && resume?.source == id) epg = resume!.epgSource;
      final channels = await compute(_readDiscoverRecent, (disk.path, id, list['name'] ?? 'Lista IPTV', epg, ids));
      for (final c in channels) {
        if (!_hiddenGroups(list).contains(c.group)) found[c.favoriteId] = c;
      }
    } catch (_) {}
  }
  if (resume != null && active.any((l) => l['id'] == resume.source && !_hiddenGroups(l).contains(resume.group))) {
    found.putIfAbsent(resume.favoriteId, () => resume);
  }
  final custom = _readIptvMap(prefs.getString('vision_iptv_custom_multi_v1'));
  final overrides = _readIptvMap(prefs.getString('vision_iptv_epg_overrides'));
  final result = <VisionDiscoverChannel>[];
  final now = DateTime.now();
  String clock(DateTime d) => '${d.toLocal().hour.toString().padLeft(2, '0')}:${d.toLocal().minute.toString().padLeft(2, '0')}';
  for (final id in ids) {
    final c = found[id];
    if (c == null) continue;
    var name = (custom['names'] as Map?)?[id] as String? ?? c.name;
    var logo = c.logo;
    _Programme? programme;
    if (c.epgSource.isNotEmpty) {
      final disk = File('${cache.path}/vision_epg_${_sourceId(c.epgSource)}.sqlite');
      if (await disk.exists()) {
        try {
          final epgId = overrides[id] as String? ?? c.tvgId;
          final data = await compute(_readIndexedGuide, (disk.path, [epgId], true));
          if (prefs.getBool('vision_iptv_use_epg_names') == true && (custom['names'] as Map?)?[id] == null) name = data.names[epgId] ?? name;
          final source = (custom['logos'] as Map?)?[id] ?? prefs.getString('vision_iptv_logo_source') ?? 'epg';
          if (source != 'm3u' || logo.isEmpty) logo = data.logos[epgId] ?? logo;
          for (final p in data.programmes[epgId] ?? const <_Programme>[]) {
            if (!now.isBefore(p.start) && now.isBefore(p.stop)) { programme = p; break; }
          }
        } catch (_) {}
      }
    }
    result.add(VisionDiscoverChannel(c, name, logo, programme?.title ?? 'Sin información EPG', programme?.description ?? '', programme == null ? '' : '${clock(programme.start)} – ${clock(programme.stop)} · En emisión'));
  }
  return result;
}

Future<void> openVisionDiscoverChannel(BuildContext context, VisionDiscoverChannel channel) async {
  await PlexTrailerPreview.stop();
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (routeContext) => VisionIptvScreen(
    discoverChannel: channel,
    onExit: () { if (routeContext.mounted) Navigator.of(routeContext).pop(); },
  )));
}

Future<void> openVisionIptvMedia(Player player, _Channel channel, bool useExo, bool forceHls) async {
      final path = Uri.parse(channel.url).path.toLowerCase();
      final isDash = path.endsWith('.mpd') || channel.manifestType == 'mpd' || channel.manifestType == 'dash';
      // Media3 infers DASH from the manifest URI when no HLS MIME is forced.
      final forceLiveHls = !useExo ||
          (!isDash && (forceHls || path.endsWith('.m3u8')));
      if (useExo) {
        final format = isDash ? 'DASH' : (forceLiveHls ? 'HLS' : 'Auto');
        debugPrint('[VisionIPTV] Exo format: $format');
      }
      debugPrint('[VisionDRM] preparing playback');
      final drmType = channel.drmType;
      final license = channel.drmLicense;
      final clearKey = drmType == 'clearkey' || drmType == 'org.w3.clearkey';
      debugPrint('[VisionDRM] DASH=$isDash DRM recognized=$clearKey license present=${license != null && license.isNotEmpty}');
      if (useExo && player is PlayerAndroid && (isDash || clearKey)) {
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
        await player.open(Media(channel.url), isLive: false, dashManifest: true,
          clearKeyLicense: localLicense, clearKeyLicenseUrl: licenseUrl);
      } else {
        await player.open(Media(channel.url), isLive: forceLiveHls);
      }
      debugPrint('[VisionDRM] open returned');
}

class VisionDiscoverPreview extends StatefulWidget {
  const VisionDiscoverPreview({super.key, required this.channel});
  final VisionDiscoverChannel channel;
  @override
  State<VisionDiscoverPreview> createState() => _VisionDiscoverPreviewState();
}
class _VisionDiscoverPreviewState extends State<VisionDiscoverPreview> {
  static Future<void> _queue = Future<void>.value();
  static Future<void> get settled => _queue;
  final _video = GlobalKey();
  Player? _player;
  StreamSubscription<void>? _frames;
  bool _ready = false, _failed = false, _cancelled = false;
  Timer? _delay;
  @override
  void initState() {
    super.initState();
    _delay = Timer(const Duration(seconds: 1), () {
      _queue = _queue.then((_) => _start()).catchError((Object _) {});
    });
  }
  Future<void> _start() async {
    if (_cancelled || !mounted) return;
    try {
      await PlexTrailerPreview.stop();
      if (_cancelled || !mounted) return;
      final prefs = await SharedPreferences.getInstance();
      if (_cancelled || !mounted) return;
      final useExo = prefs.getBool('vision_iptv_exo') ?? true;
      final c = widget.channel._channel;
      final player = Player(useExoPlayer: useExo, hardwareDecoding: true);
      _player = player;
      _frames = player.streams.playbackRestart.listen((_) {
        if (mounted && !_cancelled) { setState(() => _ready = true); _resize(); }
      });
      setState(() {});
      try {
        if (useExo) await player.setProperty('tunneled-playback', 'no');
        await player.setProperty('hwdec', 'mediacodec,mediacodec-copy');
      } catch (_) {}
      if (_cancelled || !mounted) return;
      await openVisionIptvMedia(player, c, useExo, prefs.getBool('vision_iptv_force_hls') ?? false);
      if (!_cancelled && mounted) _resize();
    } catch (_) {
      if (mounted && !_cancelled) setState(() => _failed = true);
    }
  }
  void _resize() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _cancelled || _player == null) return;
      final box = _video.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final pos = box.localToGlobal(Offset.zero), dpr = MediaQuery.devicePixelRatioOf(context);
      final channel = MethodChannel(_player is PlayerAndroid ? 'com.plezy/exo_player' : 'com.plezy/mpv_player');
      unawaited(channel.invokeMethod<void>('setIptvBounds', {'left':(pos.dx*dpr).round(),'top':(pos.dy*dpr).round(),'width':(box.size.width*dpr).round(),'height':(box.size.height*dpr).round()}).catchError((Object _) {}));
    });
  }
  @override
  void dispose() {
    _cancelled = true;
    _delay?.cancel();
    _queue = _queue.then((_) async {
      await _frames?.cancel();
      final player = _player;
      _player = null;
      if (player != null) { try { await player.dispose(); } catch (_) {} }
    }).catchError((Object _) {});
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    _resize();
    return Stack(fit: StackFit.expand, children: [
      if (_ready && !_failed) const CustomPaint(painter: _DiscoverVideoHole()),
      if (_player != null) SizedBox(key: _video, child: Video(player: _player!)),
      if (!_ready || _failed) ColoredBox(color: const Color(0xFF242A36), child: Center(child: _failed
        ? const Text('Vista previa no disponible', style: TextStyle(color: Colors.white70))
        : const CircularProgressIndicator())),
    ]);
  }
}
class _DiscoverVideoHole extends CustomPainter {
  const _DiscoverVideoHole();
  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(Offset.zero & size, Paint()..blendMode = BlendMode.clear);
  @override
  bool shouldRepaint(covariant _DiscoverVideoHole oldDelegate) => false;
}
Future<void> waitVisionDiscoverPreviewClosed() => _VisionDiscoverPreviewState.settled;

class VisionIptvScreen extends StatefulWidget {
  const VisionIptvScreen({super.key, this.settingsOnly = false, this.onExit, this.discoverChannel});
  final VisionDiscoverChannel? discoverChannel;
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
  String _epgUrl = '', _epgStatus = '';
  List<Map<String, String>> _lists = [];
  final Map<String, String> _guidePaths = {};
  final _listStatuses = ValueNotifier<Map<String,_ListStatus>>({});
  final Map<String,List<String>> _playlistGroups = {};
  Map<String,Set<String>> _hiddenBySource = {};
  bool _hidden(_Channel c) => _hiddenBySource[c.source]?.contains(c.group) ?? false;
  void _setListStatus(String id, _ListStatus status) {
    if (mounted) _listStatuses.value = {..._listStatuses.value, id: _manualRefreshQueue.contains(id) ? _ListStatus('Pendiente',detail:'Actualización en segundo plano',channels:status.channels,groups:status.groups,vod:status.vod,updated:status.updated ?? _listStatuses.value[id]?.updated) : status};
  }
  List<String> _listGroups(Map<String,String> list) => _playlistGroups[_playlistKey(list)] ?? const <String>[];
  final Map<String, Map<String, String>> _epgCatalogues = {};
  String get _listSignature => jsonEncode([_epgUrl, _lists.where((v) => v['active'] == 'true').toList()]);
  String _rawEpgId(_Channel c) => _epgOverrides[c.favoriteId] ?? c.tvgId;
  String _resolvedEpgId(_Channel c) => _epgKey(c.epgSource, _rawEpgId(c));
  Map<String, List<_Programme>> _guide = {};
  final _guideNotifier = ValueNotifier<Map<String, List<_Programme>>>({});
  Timer? _guideTimer;
  bool _guideLoading = false;
  bool _autoRefreshing = false;
  final Set<String> _manualRefreshQueue = {};
  bool _manualGuideQueued = false;
  bool get _hasManualRefresh => _manualRefreshQueue.isNotEmpty || _manualGuideQueued;
  void _queueManualList(String id) { _manualRefreshQueue.add(id); final previous = _listStatuses.value[id]; _setListStatus(id,_ListStatus('Pendiente',detail:'Actualización en segundo plano',channels:previous?.channels??0,groups:previous?.groups??0,vod:previous?.vod??0,updated:previous?.updated)); }
  void _queueManualGuide() { _manualGuideQueued = true; if (mounted) setState(()=>_epgStatus='Actualización en segundo plano pendiente'); }
  final Map<String,DateTime> _autoAttempts = {};
  final Map<String,DateTime> _epgAttempts = {};
  String _epgUpdatedLabel = 'Sin actualizar';
  String? _loadedPlaylist;
  int _guideGeneration = 0;
  bool _restoring = false;
  Set<String> _favorites = {};
  List<String> _recent = [];
  Map<String, String> _epgNames = {}, _epgOverrides = {}, _epgLogos = {};
  bool _passthrough = false, _afr = false;
  String get _customKey => 'vision_iptv_custom_multi_v1';
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
    if (widget.discoverChannel != null) _openWhenLoaded = true;
    unawaited(_restore());
  }

  Future<void> _restore() async {
    if (_restoring) return;
    _restoring = true;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _url.text = prefs.getString('vision_iptv_url') ?? '';
    _lists = _iptvLists(prefs);
    setState(() {
      _lastChannel = prefs.getString('vision_iptv_last_fullscreen');
      _resumeChannel = widget.discoverChannel?._channel ?? _Channel.fromResumeJson(prefs.getString('vision_iptv_resume_channel'));
      _quickStart = widget.discoverChannel != null || (prefs.getBool('vision_iptv_quick_start') ?? true);
      _resumeInvalid = false;
      _recent = prefs.getStringList('vision_iptv_recent') ?? [];
      _bannerSeconds = prefs.getInt('vision_iptv_banner_seconds') ?? 4;
      try { _epgOverrides = Map<String, String>.from(jsonDecode(prefs.getString('vision_iptv_epg_overrides') ?? '{}') as Map); } catch (_) { _epgOverrides = {}; }
      _favorites = (prefs.getStringList('vision_iptv_favorites') ?? []).toSet();
      _epgUrl = prefs.getString('vision_iptv_default_epg') ?? prefs.getString('vision_iptv_epg') ?? '';
      _useExoPlayer = prefs.getBool('vision_iptv_exo') ?? true;
      _tunneling = prefs.getBool('vision_iptv_tunneling') ?? false;
      _buffer = prefs.getString('vision_iptv_buffer') ?? 'minimum';
      _forceHls = prefs.getBool('vision_iptv_force_hls') ?? false;
      _passthrough = prefs.getBool('vision_iptv_passthrough') ?? false;
      _afr = prefs.getBool('vision_iptv_afr') ?? false;
    });
    _restoring = false;
    if (!widget.settingsOnly && _openWhenLoaded && !_guideOpen) { _scheduleEntry(); return; }
    if (!widget.settingsOnly) {
      if (_quickStart && _resumeChannel != null && _channels.isEmpty && !_guideOpen) {
        if (_openWhenLoaded) unawaited(_openUnifiedGuide());
      } else if (_loadedPlaylist != _listSignature || _channels.isEmpty) { await _ensureCatalog(); }
      else { unawaited(_loadGuide(cacheOnly:true)); }
    }
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
  _Channel? _resumeChannel;
  bool _quickStart = true;
  bool _resumeInvalid = false;
  Future<void>? _catalogTask;
  Future<void> _ensureCatalog() {
    if (_catalogTask != null) return _catalogTask!;
    if (_loadedPlaylist == _listSignature && _channels.isNotEmpty) return Future<void>.value();
    final task = _load(reuse:true);
    _catalogTask = task;
    return task.whenComplete(() { if (identical(_catalogTask,task)) _catalogTask = null; });
  }
  Future<void> _rememberChannel(_Channel c) async {
    if (_resumeInvalid && c.favoriteId == _resumeChannel?.favoriteId) return;
    _resumeInvalid = false;
    _lastChannel = c.favoriteId;
    _resumeChannel = c;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vision_iptv_last_fullscreen',c.favoriteId);
    await prefs.setString('vision_iptv_resume_channel',jsonEncode(c.toResumeJson()));
  }
  Future<List<_Channel>> _prepareResumeCatalog(_Channel playing, Map<String,dynamic> custom) async {
    await _ensureCatalog();
    if (!mounted) return [];
    if (!_guideLoading && _guidePaths.isEmpty) unawaited(_loadGuide(cacheOnly:true));
    final ordered = _orderedChannels(custom);
    final active = _lists.any((l) => l['id'] == playing.source && l['active'] == 'true');
    final match = ordered.indexWhere((c) => c.favoriteId == playing.favoriteId && (!_hidden(c) || _favorites.contains(c.favoriteId)));
    if (!active || (_loadedPlaylist == _listSignature && _error == null && match < 0)) {
      _resumeInvalid = true;
      if (_resumeChannel?.favoriteId == playing.favoriteId) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('vision_iptv_resume_channel');
        await prefs.remove('vision_iptv_last_fullscreen');
        _lastChannel = null;
      }
    }
    return ordered;
  }
  bool _guideOpen = false;
  bool _openWhenLoaded = false;
  void _scheduleEntry() { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _openWhenLoaded && !_guideOpen) unawaited(_openUnifiedGuide()); }); WidgetsBinding.instance.ensureVisualUpdate(); }
  Future<void> _openUnifiedGuide() async {
    if (!mounted || _guideOpen) return;
    if (_restoring) { _openWhenLoaded = true; return; }
    if (_channels.isEmpty && !(_quickStart && _resumeChannel != null)) { _openWhenLoaded = true; await _ensureCatalog(); if (!mounted || _guideOpen || !_openWhenLoaded) return; if (_channels.isEmpty) { setState(()=>_openWhenLoaded=false); _entry.requestFocus(); return; } }
    _guideOpen = true;
    _openWhenLoaded = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final custom = _readIptvMap(prefs.getString(_customKey));
      final resume = _quickStart ? _resumeChannel : null;
      final fast = resume != null;
      final ordered = resume != null ? <_Channel>[resume] : _orderedChannels(custom);
      if (!mounted || ordered.isEmpty) return;
      final first = ordered.indexWhere((c) => !_hidden(c) || _favorites.contains(c.favoriteId));
      final index = fast ? 0 : ordered.indexWhere((c) => c.favoriteId == _lastChannel && (!_hidden(c) || _favorites.contains(c.favoriteId)));
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => _IptvPlayer(startFullscreen: _quickStart && index >= 0, quickStart: _quickStart, showLoadingIndicator: prefs.getBool('vision_iptv_show_loading_indicator') ?? false, onAutomaticRefresh:_automaticRefresh, hasManualRefresh:()=>_hasManualRefresh, queueManualList:_queueManualList, queueManualGuide:_queueManualGuide, epgUpdatedLabel:()=>_epgUpdatedLabel, prepareCatalog: resume != null ? () => _prepareResumeCatalog(resume,custom) : null, channel: index >= 0 ? ordered[index] : ordered[first < 0 ? 0 : first], channels: ordered,
          guide: _guide, guideSource: _guideNotifier, allChannels: ordered,
          favoriteOrder: () => _favorites.toList(), onFavoriteOrder: _reorderFavorites, onReloadLists: _reloadListsInPlayer,
          listStatuses: _listStatuses, listGroups: _listGroups, isHidden: _hidden, listError: () => _error,
          custom: custom, customKey: _customKey, epgLogos: () => _epgLogos, logoSource: prefs.getString('vision_iptv_logo_source') ?? 'epg', useEpgNames: prefs.getBool('vision_iptv_use_epg_names') ?? false, passthrough: _passthrough, afr: _afr,
          onFavorite: _toggleFavorite, isFavorite: (c) => _favorites.contains(c.favoriteId), onFullscreen: _rememberChannel,
          recent: () => List.unmodifiable(_recent), onTuned: (c) async { await _rememberChannel(c); _recent = [c.favoriteId, ..._recent.where((id) => id != c.favoriteId)].take(30).toList(); final prefs = await SharedPreferences.getInstance(); await prefs.setStringList('vision_iptv_recent', _recent); visionDiscoverIptvChanged.value++; },
          onRefreshGuide: () => _loadGuide(force: true), guideStatus: () => _epgStatus, onGuidePage: _requestGuidePage,
          bannerSeconds: _bannerSeconds, epgNames: (c) => _epgCatalogues[c.epgSource] ?? {}, rawEpgId: _rawEpgId, epgId: _resolvedEpgId,
          onAssignEpg: (c, id) async { if (id == null) { _epgOverrides.remove(c.favoriteId); } else { _epgOverrides[c.favoriteId] = id; } final prefs = await SharedPreferences.getInstance(); await prefs.setString('vision_iptv_epg_overrides', jsonEncode(_epgOverrides)); await _reloadIndexedGuide(); },
          useExoPlayer: _useExoPlayer, tunneling: _tunneling, buffer: _buffer, forceHls: _forceHls)));
    } finally {
      _guideOpen = false;
      if (mounted) unawaited(_restore());
      if (mounted) { if (widget.onExit != null) { widget.onExit!(); } else { _entry.requestFocus(); } }
    }
  }

  List<_Channel> _orderedChannels(Map<String,dynamic> custom) {
      final ordered = List<_Channel>.of(_channels);
      final order = (custom['order'] as List?)?.whereType<String>().toList() ?? <String>[];
      if (order.isEmpty) return ordered;
      final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
      final original = {for (var i = 0; i < ordered.length; i++) ordered[i]: i};
      ordered.sort((a,b) => (rank[a.favoriteId] ?? order.length + original[a]!).compareTo(rank[b.favoriteId] ?? order.length + original[b]!));
      return ordered;
  }

  Future<void> _reorderFavorites(List<String> visibleOrder) async {
    final pending = visibleOrder.toList();
    _favorites = [for (final id in _favorites) if (visibleOrder.contains(id)) pending.removeAt(0) else id].toSet();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('vision_iptv_favorites', _favorites.toList());
  }

  Future<List<_Channel>?> _reloadListsInPlayer(Set<String> refreshIds) async {
    if (_loading || _autoRefreshing || !mounted) return null;
    final prefs = await SharedPreferences.getInstance();
    _url.text = prefs.getString('vision_iptv_url') ?? '';
    _lists = _iptvLists(prefs);
    _epgUrl = prefs.getString('vision_iptv_default_epg') ?? prefs.getString('vision_iptv_epg') ?? '';
    if (_loadedPlaylist != _listSignature || refreshIds.isNotEmpty) await _load(reuse: true, refreshIds: refreshIds);
    if (!mounted || _loadedPlaylist != _listSignature) return null;
    return _orderedChannels(_readIptvMap(prefs.getString(_customKey)));
  }

  Future<List<_Channel>?> _automaticRefresh(bool entering, bool periodic, bool Function() quiet) async {
    if (!mounted || !_guideOpen || _autoRefreshing || _loading || _guideLoading || !quiet()) return null;
    _autoRefreshing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentLists = _iptvLists(prefs);
      if (jsonEncode(currentLists.where((v)=>v['active']=='true').toList()) != jsonEncode(_lists.where((v)=>v['active']=='true').toList())) return null;
      _manualRefreshQueue.removeWhere((id)=>!_lists.any((l)=>l['id']==id && l['active']=='true'));
      if (!quiet() || !mounted || !_guideOpen || _loading || _guideLoading) return null;
      if (_manualRefreshQueue.isNotEmpty) {
        final id = _manualRefreshQueue.first;
        _manualRefreshQueue.remove(id);
        _autoAttempts[id] = DateTime.now();
        await _load(reuse:true,refreshIds:{id},background:true);
        // Reading another cached list must not erase its queued status.
        for (final queued in _manualRefreshQueue.toList()) { _queueManualList(queued); }
        if (!mounted || _loadedPlaylist != _listSignature) return null;
        return _orderedChannels(_readIptvMap(prefs.getString(_customKey)));
      }
      if (_manualGuideQueued) {
        _manualGuideQueued = false;
        await _loadGuide(force:true);
        return null;
      }
      final listHours = _refreshHours(prefs,false), epgHours = _refreshHours(prefs,true);
      final listOnEntry = prefs.getBool('vision_iptv_list_refresh_entry') ?? true;
      final epgOnEntry = prefs.getBool('vision_iptv_epg_refresh_entry') ?? true;
      final now = DateTime.now();
      if (listHours > 0 && (periodic || (entering && listOnEntry))) {
        final dir = await getApplicationSupportDirectory();
        for (final list in _lists.where((v)=>v['active']=='true')) {
          final id = list['id']!;
          final last = _autoAttempts[id];
          if (last != null && now.difference(last)<const Duration(minutes:15)) continue;
          final disk = File('${dir.path}/vision_playlist_${_playlistKey(list)}.sqlite');
          if (await disk.exists() && now.difference(await disk.lastModified())<Duration(hours:listHours)) continue;
          if (!mounted || !_guideOpen || !quiet() || _loading || _guideLoading) return null;
          _autoAttempts[id] = now;
          await _load(reuse:true,refreshIds:{id},background:true);
          if (!mounted || _loadedPlaylist != _listSignature) return null;
          return _orderedChannels(_readIptvMap(prefs.getString(_customKey)));
        }
      }
      if (!quiet() || !mounted || !_guideOpen) return null;
      // Always fetch missing EPG data on initial use; cached sources obey independent refresh settings.
      if (epgHours > 0 && (periodic || (entering && epgOnEntry))) {
        await _loadGuide(automatic:true);
      } else if (entering && _channels.any((c)=>c.epgSource.isNotEmpty && !_guidePaths.containsKey(c.epgSource))) {
        await _loadGuide();
      }
      return null;
    } catch (_) { return null; }
    finally { _autoRefreshing = false; }
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
    await prefs.setString('vision_iptv_default_epg', _epgUrl);
  }

  List<_Channel> _requestedGuideChannels = [];
  bool _readingGuidePage = false, _guidePagePending = false;
  int _guidePageVersion = 0;
  Future<void> _requestGuidePage(List<_Channel> channels) async {
    _requestedGuideChannels = channels.take(32).toList();
    _guidePageVersion++;
    _guidePagePending = true;
    if (_readingGuidePage) return;
    _readingGuidePage = true;
    try {
      while (mounted && _guidePagePending) {
        _guidePagePending = false;
        final generation = _guideGeneration, version = _guidePageVersion;
        final bySource = <String,Set<String>>{};
        for (final c in _requestedGuideChannels) {
          if (c.epgSource.isNotEmpty) (bySource[c.epgSource] ??= {}).add(_rawEpgId(c));
        }
        final programmes = <String,List<_Programme>>{};
        for (final entry in bySource.entries) {
          final path = _guidePaths[entry.key];
          if (path == null) continue;
          try {
            final data = await compute(_readIndexedGuide,(path,entry.value.toList(),false));
            for (final p in data.programmes.entries) programmes[_epgKey(entry.key,p.key)] = p.value;
          } catch (_) {}
          if (!mounted || generation != _guideGeneration || version != _guidePageVersion) break;
        }
        if (!mounted) return;
        if (generation == _guideGeneration && version == _guidePageVersion) {
          _guide = programmes;
          _guideNotifier.value = programmes;
        }
      }
    } finally { _readingGuidePage = false; }
  }

  Future<void> _reloadIndexedGuide() async {
    if (!mounted) return;
    final generation = ++_guideGeneration;
    final logos = <String,String>{};
    final catalogues = <String,Map<String,String>>{};
    for (final entry in _guidePaths.entries.toList()) {
      try {
        final data = await compute(_readIndexedGuide,(entry.value,<String>[],true));
        if (!mounted || generation != _guideGeneration) return;
        catalogues[entry.key] = data.names;
        for (final l in data.logos.entries) logos[_epgKey(entry.key,l.key)] = l.value;
      } catch (_) {}
    }
    if (!mounted || generation != _guideGeneration) return;
    _epgLogos = logos; _epgCatalogues..clear()..addAll(catalogues);
    await _requestGuidePage(_requestedGuideChannels);
  }

  Future<void> _loadGuide({bool force = false, bool automatic = false, bool cacheOnly = false}) async {
    if (_guideLoading || !mounted) return;
    final sources = _channels.where((c) => !_hidden(c) || _favorites.contains(c.favoriteId)).map((c) => c.epgSource).where((u) => u.isNotEmpty).toSet();
    if (sources.isEmpty) return;
    _guideLoading = true;
    final signature = _loadedPlaylist;
    bool failed = false, changed = false;
    try {
      final dir = await getApplicationCacheDirectory();
      final prefs = await SharedPreferences.getInstance();
      for (final url in sources) {
        final cache = File('${dir.path}/vision_epg_${_sourceId(url)}.sqlite');
        if (await cache.exists()) _guidePaths[url] = cache.path;
      }
      if (!automatic && mounted && signature == _loadedPlaylist && _guidePaths.isNotEmpty) await _reloadIndexedGuide();
      final hours = _refreshHours(prefs,true);
      for (final url in sources) {
        if (!mounted || signature != _loadedPlaylist) return;
        final uri = Uri.tryParse(url);
        if (uri == null || !['http','https'].contains(uri.scheme) || uri.host.isEmpty) { failed = true; continue; }
        final hash = _sourceId(url);
        final cache = File('${dir.path}/vision_epg_$hash.sqlite');
        final temp = File('${cache.path}.tmp');
        final xml = File('${cache.path}.xml');
        try {
          if (!await cache.exists() && prefs.getString('vision_epg_index_source_v2') == url) {
            final legacy = File('${dir.path}/vision_epg_index_v2.sqlite');
            if (await legacy.exists()) await legacy.rename(cache.path);
          }
          if (await cache.exists()) {
            if (_guidePaths[url] != cache.path) changed = true;
            _guidePaths[url] = cache.path;
            final updated = await cache.lastModified();
            if (!force && (!automatic || hours == 0 || DateTime.now().difference(updated) < Duration(hours:hours))) continue;
          }
          if (cacheOnly) continue;
          if (automatic) { final last = _epgAttempts[url]; if (last != null && DateTime.now().difference(last) < const Duration(minutes:15)) continue; _epgAttempts[url] = DateTime.now(); }
          if (mounted) setState(() => _epgStatus = 'Descargando programación…');
          final client = http.Client();
          try {
            final response = await client.send(http.Request('GET', uri)).timeout(const Duration(seconds: 45));
            if (response.statusCode != 200) throw StateError('EPG HTTP');
            await response.stream.timeout(const Duration(seconds: 45)).pipe(xml.openWrite());
          } finally { client.close(); }
          if (await temp.exists()) await temp.delete();
          if (mounted) setState(() => _epgStatus = 'Indexando programación…');
          final count = await compute(_indexGuide, (xml.path, temp.path));
          debugPrint('[VisionIPTV] indexed $count programmes');
          await temp.rename(cache.path);
          if (!mounted || signature != _loadedPlaylist) return;
          _guidePaths[url] = cache.path;
          changed = true;
        } catch (e) { failed = true; debugPrint('[VisionIPTV] EPG error: ${e.runtimeType}'); }
        finally {
          if (await xml.exists()) await xml.delete();
          if (await temp.exists()) await temp.delete();
        }
        if (automatic) break;
      }
      if (mounted && signature == _loadedPlaylist) {
        if (changed || (!automatic && _guide.isEmpty)) await _reloadIndexedGuide();
        DateTime? oldest;
        for (final url in sources) { final path = _guidePaths[url]; if (path == null) continue; try { final updated = await File(path).lastModified(); if (oldest == null || updated.isBefore(oldest)) oldest = updated; } catch (_) {} }
        if (oldest != null) { final d = oldest.toLocal(); _epgUpdatedLabel = '${d.day}/${d.month}/${d.year} ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}'; }
        if (mounted) setState(() => _epgStatus = failed ? 'Alguna EPG no se pudo actualizar' : 'Guía disponible');
      }
    } finally {
      _guideLoading = false;
      if (mounted && signature != _loadedPlaylist) unawaited(_loadGuide(cacheOnly:true));
    }
  }

  @override
  void focusActiveTabIfReady() {
    _entry.requestFocus();
    if (!widget.settingsOnly && !_guideOpen) {
      _openWhenLoaded = true;
      _scheduleEntry();
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
    _lists = _iptvLists(prefs);
    if (mounted && !widget.settingsOnly) await _load();
  }

  Future<void> _load({bool reuse = false, Set<String> refreshIds = const {}, bool background = false}) async {
    if (_loading || !mounted) return;
    final active = _lists.where((v) => v['active'] == 'true').toList();
    final signature = _listSignature;
    final hidden = {for (final list in active) list['id']!: _hiddenGroups(list)};
    if (active.isEmpty) {
      setState(() { _channels = []; _guide = {}; _error = 'Activa una lista IPTV en Ajustes.'; });
      _loadedPlaylist = signature; _hiddenBySource = {}; _guidePaths.clear(); _guideGeneration++;
      _guideNotifier.value = {};
      return;
    }
    setState(() { _loading = true; if (!background) _error = null; });
    final channels = <_Channel>[];
    int failures = 0;
    try {
      for (final list in active) {
        final id = list['id']!;
        final uri = Uri.tryParse(list['url'] ?? '');
        if (uri == null || !['http','https'].contains(uri.scheme) || uri.host.isEmpty) {
          failures++; _setListStatus(id, const _ListStatus('Error', detail: 'URL no válida')); continue;
        }
        final key = _playlistKey(list);
        final dir = await getApplicationSupportDirectory();
        final disk = File('${dir.path}/vision_playlist_$key.sqlite');
        final pending = File('${disk.path}.tmp');
        final hiddenGroups = hidden[id] ?? <String>{};
        final savedFavorites = _favorites.where((fav) {
          try { return (jsonDecode(fav) as List).first == id; } catch (_) { return false; }
        }).toSet();
        _PlaylistSnapshot? data;
        DateTime? updated;
        bool downloadFailed = false;
        if (reuse && !refreshIds.contains(id) && await disk.exists()) {
          try {
            _setListStatus(id, const _ListStatus('Leyendo caché…'));
            data = await compute(_readPlaylistSnapshot,(disk.path,id,hiddenGroups,savedFavorites));
            updated = await disk.lastModified();
          } catch (_) { try { await disk.delete(); } catch (_) {} }
        }
        if (data == null) {
          File? temp;
          try {
            final previous = _listStatuses.value[id];
            _setListStatus(id, _ListStatus('Descargando…',channels:previous?.channels??0,groups:previous?.groups??0,vod:previous?.vod??0,updated:previous?.updated));
            final cacheDir = await getApplicationCacheDirectory();
            temp = File('${cacheDir.path}/vision_m3u_$key.tmp');
            if (await pending.exists()) await pending.delete();
            await compute(_downloadPlaylistSnapshot,(Map<String,String>.of(list),pending.path,temp.path));
            if (background && (!mounted || signature != _listSignature)) return;
            await pending.rename(disk.path);
            data = await compute(_readPlaylistSnapshot,(disk.path,id,hiddenGroups,savedFavorites));
            updated = await disk.lastModified();
          } catch (e) {
            failures++; downloadFailed = true;
            final reason = e is TimeoutException ? 'Tiempo de descarga agotado' : e is _PlaylistHttpError ? 'HTTP ${e.status}' : e is _XtreamError ? e.message : e is FormatException ? 'Respuesta no válida o sin canales en directo' : 'Fallo de red o lectura (${e.runtimeType})';
            debugPrint('[VisionIPTV] playlist error: $reason');
            if (await disk.exists()) {
              try { data = await compute(_readPlaylistSnapshot,(disk.path,id,hiddenGroups,savedFavorites)); updated = await disk.lastModified(); } catch (_) {}
            }
            _setListStatus(id, _ListStatus('Error', detail: data == null ? reason : '$reason · conservando copia anterior', channels: data?.total ?? 0, groups: data?.groups.length ?? 0, vod: data?.vod ?? 0, updated: updated));
          } finally {
            if (temp != null) { try { if (await temp.exists()) await temp.delete(); } catch (_) {} }
            try { if (await pending.exists()) await pending.delete(); } catch (_) {}
          }
        }
        if (data == null) continue;
        _playlistGroups[key] = data.groups;
        final items = data.channels, autoEpg = data.epg;
        if (!downloadFailed) _setListStatus(id, _ListStatus('Cargada', channels: data.total, groups: data.groups.length, vod: data.vod, updated: updated));
        final customEpg = list['epg'] ?? '';
        final epg = customEpg.isNotEmpty ? customEpg : _epgUrl.isNotEmpty ? _epgUrl : autoEpg;
        channels.addAll(items.map((c) => c.withSource(id, list['name'] ?? 'Lista IPTV', epg)));
      }
      if (!mounted || (background && signature != _listSignature)) return;
      if (channels.isEmpty && failures > 0) throw StateError('Empty');
      final prefs = await SharedPreferences.getInstance();
      await _migrateIptvSettings(prefs, channels);
      if (!mounted) return;
      setState(() { _channels = channels; _hiddenBySource = hidden; _error = failures > 0 ? 'Alguna lista no se pudo cargar · revisa Listas IPTV' : null; });
      _loadedPlaylist = signature; _guideGeneration++;
      final sources = channels.map((c) => c.epgSource).toSet();
      _guidePaths.removeWhere((k,v) => !sources.contains(k));
      _playlistGroups.removeWhere((k,v) => !active.any((l) => _playlistKey(l) == k));
      if (!background) { _guide = {}; _guideNotifier.value = {}; _epgCatalogues.clear(); _epgLogos = {}; }
      if (_openWhenLoaded && !_guideOpen) _scheduleEntry();
      if (!background) unawaited(_loadGuide(cacheOnly:true));
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo cargar ninguna lista IPTV.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _migrateIptvSettings(SharedPreferences prefs, List<_Channel> channels) async {
    final custom = _readIptvMap(prefs.getString(_customKey));
    final names = Map<String,dynamic>.from(custom['names'] as Map? ?? {});
    final logos = Map<String,dynamic>.from(custom['logos'] as Map? ?? {});
    final order = (custom['order'] as List?)?.whereType<String>().toList() ?? <String>[];
    final migrated = (prefs.getStringList('vision_iptv_migrated_sources') ?? []).toSet();
    bool changed = false;
    for (final list in _lists.where((v) => v['active'] == 'true')) {
      final source = list['id'] ?? _sourceId(list['url'] ?? '');
      if (migrated.contains(source)) continue;
      final items = channels.where((c) => c.source == source).toList();
      if (items.isEmpty) continue;
      final ids = {for (final c in items) c.legacyId: c.favoriteId};
      final legacy = _readIptvMap(prefs.getString('vision_iptv_custom_${list['url']}'));
      for (final key in ['names','logos']) {
        final target = key == 'names' ? names : logos;
        final values = legacy[key];
        if (values is Map) { for (final e in values.entries) { final id = ids[e.key]; if (id != null) target.putIfAbsent(id, () => e.value); } }
      }
      final oldOrder = legacy['order'];
      if (oldOrder is List) { for (final id in oldOrder) { final next = ids[id]; if (next != null && !order.contains(next)) order.add(next); } }
      // Legacy favourites and overrides were global; migrate them only for
      // the original active list to avoid assigning them to duplicates.
      if (list['url'] == _url.text) {
        _favorites = _favorites.map((id) => ids[id] ?? id).toSet();
        _recent = _recent.map((id) => ids[id] ?? id).toList();
        _lastChannel = ids[_lastChannel] ?? _lastChannel;
        _epgOverrides = {for (final e in _epgOverrides.entries) ids[e.key] ?? e.key: e.value};
      }
      migrated.add(source); changed = true;
    }
    if (!changed) return;
    custom['names'] = names; custom['logos'] = logos; custom['order'] = order;
    await prefs.setString(_customKey, jsonEncode(custom));
    await prefs.setStringList('vision_iptv_migrated_sources', migrated.toList());
    await prefs.setStringList('vision_iptv_favorites', _favorites.toList());
    await prefs.setStringList('vision_iptv_recent', _recent);
    if (_lastChannel != null) await prefs.setString('vision_iptv_last_fullscreen', _lastChannel!);
    await prefs.setString('vision_iptv_epg_overrides', jsonEncode(_epgOverrides));
  }

  @override
  void dispose() {
    if (!widget.settingsOnly) _iptvSettingsChanged.removeListener(_settingsUpdated);
    _guideTimer?.cancel();
    _guideNotifier.dispose();
    _listStatuses.dispose();
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
        ListTile(title: const Text('Guía de uso del mando'), leading: const Icon(Icons.help_outline), onTap: () => _showIptvRemoteHelp(context)),
        ListTile(title: const Text('Actualizar lista y guía'), subtitle: Text(_epgStatus), onTap: () async { await _load(); if (mounted) await _loadGuide(force: true); }),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) ListTile(title: Text(_error!)),
      ])),
    );
    return Scaffold(body: SafeArea(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (_channels.isEmpty && !_restoring && !_openWhenLoaded && !_loading && _error != null) Text('TV en directo · IPTV', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 14),
      if (_loading || _restoring || _openWhenLoaded) const Text('Cargando TV en vivo…',style:TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.w600)),
      if (_error != null) Text(_error!),
      if (_channels.isNotEmpty || (_quickStart && _resumeChannel != null))
        Focus(focusNode: _entry, autofocus: true, onFocusChange: (focused) { if (focused && !_guideOpen && _openWhenLoaded) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) unawaited(_openUnifiedGuide()); }); }, onKeyEvent: (_, event) { if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.enter)) { unawaited(_openUnifiedGuide()); return KeyEventResult.handled; } return KeyEventResult.ignored; }, child: const SizedBox.shrink())
      else if (!_loading && !_restoring && !_openWhenLoaded)
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
  const _IptvPlayer({required this.startFullscreen, required this.quickStart, required this.showLoadingIndicator, required this.onAutomaticRefresh, required this.hasManualRefresh, required this.queueManualList, required this.queueManualGuide, required this.epgUpdatedLabel, this.prepareCatalog, required this.favoriteOrder, required this.onFavoriteOrder, required this.onReloadLists, required this.listStatuses, required this.listGroups, required this.isHidden, required this.listError, required this.onFullscreen, required this.bannerSeconds, required this.epgNames, required this.rawEpgId, required this.epgId, required this.onAssignEpg, required this.recent, required this.onTuned, required this.onRefreshGuide, required this.onGuidePage, required this.guideStatus, required this.channel, required this.channels, required this.guide, required this.guideSource, required this.allChannels, required this.onFavorite, required this.isFavorite, required this.useExoPlayer, required this.tunneling, required this.buffer, required this.forceHls, required this.custom, required this.customKey, required this.epgLogos, required this.logoSource, required this.useEpgNames, required this.passthrough, required this.afr});
  final Map<String, dynamic> custom;
  final String customKey, logoSource;
  final bool useEpgNames;
  final Map<String, String> Function() epgLogos;
  final bool passthrough, afr;
  final bool startFullscreen, quickStart, showLoadingIndicator;
  final Future<List<_Channel>> Function()? prepareCatalog;
  final Future<List<_Channel>?> Function(bool,bool,bool Function()) onAutomaticRefresh;
  final bool Function() hasManualRefresh;
  final void Function(String) queueManualList;
  final VoidCallback queueManualGuide;
  final String Function() epgUpdatedLabel;
  final List<String> Function() favoriteOrder;
  final Future<void> Function(List<String>) onFavoriteOrder;
  final Future<List<_Channel>?> Function(Set<String>) onReloadLists;
  final ValueNotifier<Map<String,_ListStatus>> listStatuses;
  final List<String> Function(Map<String,String>) listGroups;
  final bool Function(_Channel) isHidden;
  final String? Function() listError;
  final Future<void> Function(_Channel) onFullscreen;
  final int bannerSeconds;
  final Map<String, String> Function(_Channel) epgNames;
  final String Function(_Channel) rawEpgId;
  final String Function(_Channel) epgId;
  final Future<void> Function(_Channel, String?) onAssignEpg;
  final List<String> Function() recent;
  final Future<void> Function(_Channel) onTuned;
  final Future<void> Function() onRefreshGuide;
  final Future<void> Function(List<_Channel>) onGuidePage;
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
  bool _pendingTuneBanner = false;
  Timer? _timer;
  String _technical = '';
  bool _readingStats = false;
  Future<void>? _closing;
  late int _channelIndex;
  late int _highlightIndex;
  bool _switching = false, _showChannels = false, _preview = true, _tuned = false;
  bool _verticalGuide = false;
  int _verticalColumn = 0, _verticalProgrammeIndex = -1;
  int? _verticalChannelIndex;
  DateTime? _verticalProgrammeStart;
  final _verticalChannelsScroll = ScrollController(), _verticalProgrammesScroll = ScrollController(), _verticalSynopsisScroll = ScrollController();
  double _verticalChannelExtent = 46, _verticalProgrammeExtent = 42;
  String? _verticalGroupKey, _verticalGroupFocus;
  final _verticalGroupsScroll = ScrollController();
  double _verticalGroupExtent = 38;
  List<String> get _verticalGroups => ['Favoritos','Todos','Últimos canales',..._groups.skip(2)];
  void _scrollVerticalGroups() { WidgetsBinding.instance.addPostFrameCallback((_) { if (!mounted || !_verticalGuide || !_verticalGroupsScroll.hasClients) return; final i = _verticalGroups.indexOf(_verticalGroupFocus ?? 'Todos'); final p = _verticalGroupsScroll.position; if (i>=0) _verticalGroupsScroll.jumpTo((i*_verticalGroupExtent-p.viewportDimension/2+_verticalGroupExtent/2).clamp(0.0,p.maxScrollExtent).toDouble()); }); }
  void _openVerticalGroups() { setState(() { final key = _verticalGroupKey ?? _groupKey(_channel.source,_channel.group); final parts = _groupParts(key); if (parts != null && parts[1] != null) { _expandedSources.add(parts[0] as String); _groupTree = null; } _verticalGroupFocus = _verticalGroups.contains(key)?key:'Todos'; _verticalColumn = -1; }); _scrollVerticalGroups(); }
  void _moveVerticalGroup(int delta) { final groups = _verticalGroups; final i = groups.indexOf(_verticalGroupFocus ?? 'Todos'); final next = (i+delta).clamp(0,groups.length-1).toInt(); if (next==i) return; setState(()=>_verticalGroupFocus=groups[next]); _chooseVerticalGroup(focusOnly:true); _scrollVerticalGroups(); }
  void _chooseVerticalGroup({bool enterChannels=false,bool focusOnly=false}) { final key = _verticalGroupFocus ?? 'Todos'; final parts = _groupParts(key); if (!focusOnly && !enterChannels && parts != null && parts[1]==null) { setState(() { final source=parts[0] as String; if (!_expandedSources.remove(source)) _expandedSources.add(source); _groupTree=null; widget.custom['expanded']=_expandedSources.toList(); }); unawaited(_saveCustom()); _scrollVerticalGroups(); return; } final previous = _verticalSelected; setState(() { _verticalGroupKey=key; final rows=_verticalRows; if (rows.isNotEmpty) { final next=rows.contains(previous)?previous:rows.first; if (next!=previous) { _verticalChannelIndex=next; _verticalProgrammeStart=null; _syncVerticalProgramme(reset:true); } } if (enterChannels) _verticalColumn=0; }); _scheduleGuidePage(); _scrollVerticalBoth(); }

  int _groupIndex = 0, _programmeIndex = -1, _timeShift = 0;
  bool _groupFocus = false;
  bool _menuOpen = false, _recentOnly = false;
  bool _settingsOpen = false, _settingsDirty = false, _listsDirty = false, _applyingLists = false;
  final Set<String> _refreshListIds = {};
  late int _bannerSeconds = widget.bannerSeconds;
  _Programme? _bannerProgramme;
  bool _zooming = false;
  int _zoomGeneration = 0;
  bool _fastScroll = false;
  LogicalKeyboardKey? _pendingChannelWrap;
  void _guideChannelArrow(KeyEvent event, {required bool vertical}) {
    final key = event.logicalKey;
    final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
    final rows = vertical ? _verticalRows : _visibleIndices;
    final index = rows.indexOf(vertical ? _verticalSelected : _highlightIndex);
    void move(bool wrap) { if (vertical) { _moveVertical(delta,wrap:wrap); } else { _moveRow(delta,wrap:wrap); } }
    if (event is KeyDownEvent) {
      _pendingChannelWrap = null;
      if (index >= 0 && (index + delta < 0 || index + delta >= rows.length)) { _pendingChannelWrap = key; } else { move(false); }
    } else if (event is KeyRepeatEvent) {
      _pendingChannelWrap = null;
      if (!_fastScroll) setState(() => _fastScroll = true);
      move(false);
    } else if (event is KeyUpEvent) {
      final wrap = _pendingChannelWrap == key && !_fastScroll;
      _pendingChannelWrap = null;
      if (_fastScroll) setState(() => _fastScroll = false);
      if (wrap) move(true);
    }
  }
  bool _guideSelectDown = false, _contextSelectDown = false, _favoriteLong = false;
  Timer? _favoriteHold, _statusTimer;
  DateTime? _guideAnchor;
  bool _dialogBusy = false;
  PhysicalKeyboardKey? _blockedGuideOk;
  Timer? _consultationIdle;
  ModalRoute<dynamic>? _consultationRoute;
  bool _idleClosing = false;

  KeyEventResult _iptvEarlyKey(KeyEvent event) {
    if (!mounted || _exiting) return KeyEventResult.ignored;
    _lastInteraction = DateTime.now();
    if (_blockedGuideOk == event.physicalKey) {
      if (event is KeyUpEvent) {
        _blockedGuideOk = null;
        _guideSelectDown = false;
        _favoriteLong = false;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<T?> _consultationDialog<T>({required WidgetBuilder builder, Color barrierColor = Colors.black54}) async {
    try {
      return await showDialog<T>(context: context, barrierColor: barrierColor, builder: (ctx) {
        _consultationRoute = ModalRoute.of(ctx);
        return builder(ctx);
      });
    } finally {
      _consultationRoute = null;
    }
  }

  void _checkConsultationIdle() {
    if (!mounted || _exiting || _idleClosing) return;
    final route = _consultationRoute;
    if (_settingsOpen || _applyingLists || (_dialogBusy && route == null)) {
      _lastInteraction = DateTime.now();
      return;
    }
    if (!_tuned || !_ready || _failed || _switching || _zooming || _player == null) return;
    if (DateTime.now().difference(_lastInteraction) < const Duration(seconds: 60)) return;
    if (route != null) {
      if (!route.isCurrent) return;
      _idleClosing = true;
      route.navigator?.pop();
      return;
    }
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _returnFromConsultation();
  }

  void _returnFromConsultation() {
    if (!mounted || _exiting || _settingsOpen || !_tuned || !_ready || _failed || _switching || _player == null) return;
    if (_verticalGuide) {
      _closeVerticalGuide();
    } else if (_preview) {
      _finishPreview(false);
    } else if (_showChannels || _menuOpen) {
      _timer?.cancel();
      final showTune = _pendingTuneBanner;
      _pendingTuneBanner = false;
      setState(() { _showChannels = false; _menuOpen = false; _showName = showTune; _bannerProgramme = null; });
      if (showTune) _hideLater();
      _playerFocus.requestFocus();
    }
    _lastInteraction = DateTime.now();
  }
  bool _menuSelectDown = false, _settingsSelectDown = false;
  static const _bannerChoices = [2, 3, 4, 5, 7, 10, 15, 0];
  int _settingsIndex = 0;
  String? _settingsSection;
  static const _settingsSections = ['section_lists','section_guide','section_appearance','section_playback','section_behavior','section_backup','section_remote_help'];
  static const _settingsSectionLabels = <String,String>{'section_lists':'Listas IPTV','section_guide':'Guía de programación','section_appearance':'Interfaz y apariencia','section_playback':'Reproducción','section_behavior':'Comportamiento','section_backup':'Copia de seguridad','section_remote_help':'Guía de uso del mando'};
  void _resetSettingsScroll() { if (_settingsScroll.hasClients) _settingsScroll.jumpTo(0); }
  void _leaveSettingsSection() { final section = _settingsSection; setState(() { _settingsSection = null; _settingsIndex = _settingsSections.indexOf(section ?? '').clamp(0,_settingsSections.length-1).toInt(); }); WidgetsBinding.instance.addPostFrameCallback((_) { if (!mounted || !_settingsOpen || !_settingsScroll.hasClients) return; final p = _settingsScroll.position; _settingsScroll.jumpTo((_settingsIndex*44.0-p.viewportDimension/2+22).clamp(0.0,p.maxScrollExtent).toDouble()); }); }
  String _settingsUrl = '', _settingsEpg = '', _settingsBuffer = 'minimum';
  bool _settingsExo = true, _settingsHls = false, _settingsTunnel = false;
  bool _settingsPassthrough = false, _settingsAfr = false;
  bool _discoverRow = true;
  late String _logoSource = widget.logoSource;
  late bool _useEpgNames = widget.useEpgNames;
  late bool _quickStartSetting = widget.quickStart;
  late bool _showLoadingIndicator = widget.showLoadingIndicator;
  bool _listRefreshEntry = true, _epgRefreshEntry = true;
  int _listRefreshHours = 24, _epgRefreshHours = 6;
  late bool _preparingCatalog = widget.prepareCatalog != null;
  bool _catalogStarted = false;
  String? _catalogError;
  Timer? _catalogFallback, _autoRefreshTimer;
  bool _autoRunning = false, _autoEntryPending = true;
  DateTime _lastInteraction = DateTime.now();
  DateTime? _autoFirstReady, _lastAutoCheck;
  List<_Channel>? _pendingAutoChannels;
  bool get _autoQuiet => mounted && !_exiting && !_preparingCatalog && !_switching && !_zooming && !_afrSwitching && !_dialogBusy && !_applyingLists && !_settingsOpen && !_menuOpen && !_fastScroll && !_listsDirty && _ready && !_failed && DateTime.now().difference(_lastInteraction)>=const Duration(seconds:8) && (_autoFirstReady == null || DateTime.now().difference(_autoFirstReady!)>=const Duration(seconds:10));
  Future<void> _runAutomaticRefresh() async {
    if (_autoRunning || !_autoQuiet) return;
    if (_pendingAutoChannels != null) { final next = _pendingAutoChannels!; _pendingAutoChannels = null; _integrateAutoChannels(next); return; }
    _autoRunning = true;
    final entering = _autoEntryPending;
    final periodic = _autoFirstReady != null && DateTime.now().difference(_autoFirstReady!) >= const Duration(minutes:2);
    if (!widget.hasManualRefresh() && !entering && (!periodic || (_lastAutoCheck != null && DateTime.now().difference(_lastAutoCheck!)<const Duration(minutes:1)))) { _autoRunning = false; return; }
    _lastAutoCheck = DateTime.now();
    try {
      final next = await widget.onAutomaticRefresh(entering,periodic,()=>_autoQuiet);
      if (!mounted || _exiting) return;
      if (next != null && next.isNotEmpty) { _pendingAutoChannels = next; if (_autoQuiet) { _pendingAutoChannels = null; _integrateAutoChannels(next); } }
      else if (_autoQuiet) _autoEntryPending = false;
    } finally { _autoRunning = false; }
  }
  void _integrateAutoChannels(List<_Channel> next) {
    if (next.isEmpty || !_autoQuiet) return;
    final playing = _channel, highlighted = widget.channels[_highlightIndex];
    final vertical = widget.channels[_verticalSelected];
    final group = _selectedGroup;
    final playingIndex = next.indexWhere((c)=>c.favoriteId==playing.favoriteId && c.url==playing.url);
    final stale = playingIndex<0;
    final retained = stale ? [...next,playing] : next;
    final selection = retained.indexWhere((c)=>c.favoriteId==highlighted.favoriteId);
    final verticalSelection = retained.indexWhere((c)=>c.favoriteId==vertical.favoriteId);
    final anchor = _selectedProgramme?.start ?? _guideAnchor;
    setState(() {
      widget.channels..clear()..addAll(retained);
      _rebuildChannelIndices();
      if (stale) {
        final i = retained.length-1;
        for (final rows in _groupRows.values) { rows.remove(i); }
        _channelIndices.remove(playing.favoriteId);
        final replacement = next.indexWhere((c)=>c.favoriteId==playing.favoriteId);
        if (replacement>=0) _channelIndices[playing.favoriteId]=replacement;
      }
      _channelIndex = stale?retained.length-1:playingIndex;
      final g = _groups.indexOf(group); _groupIndex = g<0?0:g;
      final rows = _visibleIndices;
      _highlightIndex = selection>=0 && rows.contains(selection)?selection:rows.contains(_channelIndex)?_channelIndex:rows.isNotEmpty?rows.first:_channelIndex;
      if (_preview) { final at = anchor??DateTime.now(); _programmeIndex = _programmes(_highlightIndex).indexWhere((p)=>!at.isBefore(p.start)&&at.isBefore(p.stop)); }
      if (_verticalGuide) { final vr = _verticalRows; _verticalChannelIndex = verticalSelection>=0&&vr.contains(verticalSelection)?verticalSelection:vr.contains(_channelIndex)?_channelIndex:vr.isNotEmpty?vr.first:_channelIndex; _syncVerticalProgramme(); }
    });
    _scheduleGuidePage();
    if (_preview) { _scrollPreview(); _scrollGroup(); }
    if (_verticalGuide) _scrollVerticalBoth();
  }
  int _afrGeneration = 0;
  bool _afrSwitching = false, _externalPicker = false;
  void _beginCatalog() {
    if (!_preparingCatalog || _catalogStarted || !mounted || _exiting) return;
    _catalogStarted = true;
    _catalogFallback?.cancel();
    unawaited(_completeCatalog());
  }
  Future<void> _completeCatalog() async {
    final playing = _channel;
    try {
      final next = await widget.prepareCatalog!();
      if (!mounted || _exiting) return;
      if (next.isEmpty) {
        setState(() { _preparingCatalog = false; _catalogError = widget.listError() ?? 'No hay canales disponibles'; _groupFocus = true; });
        return;
      }
      final index = next.indexWhere((c) => c.favoriteId == playing.favoriteId && c.url == playing.url);
      // Keep the currently open stream even if it disappeared or changed URL in the list.
      // It is not inserted into visible groups unless it is still in the catalogue.
      final retained = index >= 0 ? next : [...next,playing];
      setState(() {
        widget.channels..clear()..addAll(retained);
        _rebuildChannelIndices();
        if (index < 0) {
          final stale = retained.length - 1;
          for (final rows in _groupRows.values) { rows.remove(stale); }
          _channelIndices.remove(playing.favoriteId);
          final replacement = next.indexWhere((c) => c.favoriteId == playing.favoriteId);
          if (replacement >= 0) _channelIndices[playing.favoriteId] = replacement;
        }
        _channelIndex = index >= 0 ? index : retained.length - 1;
        final rows = _visibleIndices;
        _highlightIndex = rows.contains(_channelIndex) || rows.isEmpty ? _channelIndex : rows.first;
        _programmeIndex = -1;
        if (_preview) _stepProgramme(0);
        _preparingCatalog = false;
        if (_verticalGuide) { _verticalChannelIndex = _channelIndex; if (_verticalGroupKey != 'Favoritos') _verticalGroupKey = _groupKey(_channel.source,_channel.group); _syncVerticalProgramme(reset:true); }
      });
      _scrollPreview();
      if (_verticalGuide) _scrollVerticalBoth();
    } catch (_) {
      if (mounted) setState(() { _preparingCatalog = false; _catalogError = 'No se pudo preparar la guía'; _groupFocus = true; });
    }
  }
  String _name(_Channel c) {
    final custom = (widget.custom['names'] as Map?)?[c.favoriteId] as String?;
    if (custom != null && custom.trim().isNotEmpty) return custom;
    if (_useEpgNames) {
      final id = widget.rawEpgId(c);
      final name = id.isEmpty ? null : widget.epgNames(c)[id]?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return c.name;
  }
  String _logo(_Channel c) {
    final choice = (widget.custom['logos'] as Map?)?[c.favoriteId] as String? ?? _logoSource;
    final epg = widget.epgLogos()[widget.epgId(c)] ?? '';
    return choice == 'm3u' ? (c.logo.isNotEmpty ? c.logo : epg) : (epg.isNotEmpty ? epg : c.logo);
  }
  Future<void> _saveCustom() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(widget.customKey, jsonEncode(widget.custom));
  }
  final _settingsScroll = ScrollController();
  int _menuIndex = 0;
  String _status = '';
  String get _menuStatus => _status;
  set _menuStatus(String value) {
    _statusTimer?.cancel();
    _status = value;
    if (value.isNotEmpty && value != 'Actualizando…' && value != 'Aplicando listas…') {
      _statusTimer = Timer(const Duration(seconds: 4), () { if (mounted) setState(() => _status = ''); });
    }
  }
  static const _menuLabels = ['Guía de televisión', 'Favoritos', 'Últimos canales', 'Actualizar programación', 'Ajustes IPTV', 'Salir de IPTV'];
  static const _menuIcons = [Icons.calendar_today, Icons.star_border, Icons.history, Icons.refresh, Icons.settings, Icons.exit_to_app];
  bool _inProgrammes = true;
  Timer? _leftHold, _backHold;
  bool _leftLong = false, _backLong = false;
  bool _exiting = false;
  final _videoKey = GlobalKey();
  Rect? _zoomRect;
  bool get _smallVideo => _preview || _verticalGuide;
  Future<void> _resizeVideo() async {
    if (!mounted || _player == null || _closing != null || _zooming) return;
    final box = _videoKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final pos = box.localToGlobal(Offset.zero);
    try {
      final player = _player!;
      if (player is PlayerAndroid) {
        await const MethodChannel('com.plezy/exo_player').invokeMethod('setIptvBounds', {'left': _smallVideo ? (pos.dx*dpr).round() : 0, 'top': _smallVideo ? (pos.dy*dpr).round() : 0, 'width': _smallVideo ? (box.size.width*dpr).round() : 0, 'height': _smallVideo ? (box.size.height*dpr).round() : 0});
      } else {
        await const MethodChannel('com.plezy/mpv_player').invokeMethod('setIptvBounds', {'left': _smallVideo ? (pos.dx*dpr).round() : 0, 'top': _smallVideo ? (pos.dy*dpr).round() : 0, 'width': _smallVideo ? (box.size.width*dpr).round() : 0, 'height': _smallVideo ? (box.size.height*dpr).round() : 0});
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
    return p == null ? _timeShift == 0 && _guideAnchor == null : !now.isBefore(p.start) && now.isBefore(p.stop);
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
    if (_zooming || _applyingLists) return;
    if (_verticalGuide) { if (_settingsOpen) { _closeSettings(); } else { _closeVerticalGuide(); } return; }
    if (_preparingCatalog && !_preview) { _beginCatalog(); _previewMode(true); return; }
    if (_preparingCatalog && _preview) { _previewMode(false); return; }
    if (!_preview) { if (_showName) { _timer?.cancel(); setState(() { _showName = false; _bannerProgramme = null; }); } else { _previewMode(true); } return; }
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
    if (entries.isEmpty) { _programmeIndex = -1; if (delta == 0) _guideAnchor = null; return; }
    final visible = _programmes(_highlightIndex);
    final selected = _programmeIndex >= 0 && _programmeIndex < visible.length ? visible[_programmeIndex] : null;
    final now = DateTime.now();
    if (delta == 0) {
      _guideAnchor = null;
      _programmeIndex = visible.indexWhere((p) => !now.isBefore(p.start) && now.isBefore(p.stop));
      return;
    }
    final anchor = _guideAnchor ?? now;
    var index = selected == null ? entries.indexWhere((p) => p.stop.isAfter(anchor)) : entries.indexOf(selected) + delta;
    if (selected == null && delta < 0) index--;
    if (selected == null && index < 0 && delta < 0) index = entries.length - 1;
    if (index < 0 || index >= entries.length) return;
    final target = entries[index];
    final start = _windowStart;
    if (!target.stop.isAfter(start) || !target.start.isBefore(start.add(const Duration(hours: 2)))) {
      final now = DateTime.now();
      final base = DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30);
      _timeShift = (target.start.difference(base).inSeconds / 1800).floor();
    }
    _programmeIndex = _programmes(_highlightIndex).indexOf(target);
    _guideAnchor = !now.isBefore(target.start) && now.isBefore(target.stop) ? null : target.start;
  }
  Map<String, List<_Programme>> get _guide => widget.guideSource.value;
  Map<String,String> _sourceLabels = {};
  Map<String,List<String>> _sourceGroups = {};
  Map<String,List<int>> _groupRows = {};
  Map<String,int> _channelIndices = {};
  List<String>? _groupTree;
  void _rebuildChannelIndices() {
    final labels = <String,String>{};
    final groups = <String,Set<String>>{};
    final rows = <String,List<int>>{'Todos': []};
    final indices = <String,int>{};
    for (var i = 0; i < widget.channels.length; i++) {
      final c = widget.channels[i];
      indices[c.favoriteId] = i;
      labels[c.source] = c.sourceName;
      groups.putIfAbsent(c.source, () => <String>{});
      if (widget.isHidden(c)) continue;
      groups[c.source]!.add(c.group);
      rows['Todos']!.add(i);
      for (final key in [_groupKey(c.source,null),_groupKey(c.source,''),_groupKey(c.source,c.group)].toSet()) {
        (rows[key] ??= <int>[]).add(i);
      }
    }
    _sourceLabels = labels;
    _sourceGroups = {for (final e in groups.entries) e.key:e.value.toList()};
    _groupRows = rows; _channelIndices = indices; _groupTree = null;
  }
  late final Set<String> _expandedSources = ((widget.custom['expanded'] as List?)?.whereType<String>() ?? _sourceLabels.keys.take(1)).toSet();
  List<String> get _groups => _groupTree ??= ['Todos', 'Favoritos', for (final source in _sourceLabels.keys) ...[
    _groupKey(source, null), if (_expandedSources.contains(source)) ...[_groupKey(source, ''), for (final group in _sourceGroups[source]!) _groupKey(source, group)]
  ]];
  String _groupKey(String source, String? group) => jsonEncode([source, group]);
  List<dynamic>? _groupParts(String key) => key.startsWith('[') ? jsonDecode(key) as List : null;
  String _groupLabel(String key) {
    final p = _groupParts(key);
    if (p == null) return key == 'Todos' ? 'Todos los canales' : key;
    return p[1] == null ? _sourceLabels[p[0]] ?? 'Lista IPTV' : p[1] == '' ? 'Todos' : p[1] as String;
  }
  String get _selectedGroup => _groups[_groupIndex.clamp(0, _groups.length - 1).toInt()];
  List<int> get _visibleIndices {
    if (_recentOnly || _selectedGroup == 'Favoritos') {
      return [for (final id in (_recentOnly ? widget.recent() : widget.favoriteOrder())) if (_channelIndices.containsKey(id) && (!_recentOnly || !widget.isHidden(widget.channels[_channelIndices[id]!]) || widget.isFavorite(widget.channels[_channelIndices[id]!])) ) _channelIndices[id]!];
    }
    return _groupRows[_selectedGroup] ?? const <int>[];
  }
  bool _toggleGroupHeader() {
    final p = _groupParts(_selectedGroup);
    if (p == null || p[1] != null) return false;
    final id = p[0] as String;
    final key = _selectedGroup;
    setState(() {
      if (!_expandedSources.remove(id)) _expandedSources.add(id);
      widget.custom['expanded'] = _expandedSources.toList();
      _groupTree = null;
      _groupIndex = _groups.indexOf(key);
    });
    unawaited(_saveCustom());
    _scrollGroup();
    return true;
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
      _groupScroll.jumpTo(((_groupIndex - 2) * 38.0 - p.viewportDimension / 2 + 19).clamp(0.0, p.maxScrollExtent).toDouble());
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
        widget.queueManualGuide();
        setState(() => _menuStatus = 'Actualización EPG en segundo plano solicitada');
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
    if (!mounted || (!_menuOpen && !(_verticalGuide && _verticalColumn==-2)) || _exiting) return;
    setState(() {
      _settingsUrl = prefs.getString('vision_iptv_url') ?? '';
      _settingsEpg = prefs.getString('vision_iptv_default_epg') ?? prefs.getString('vision_iptv_epg') ?? '';
      _settingsExo = prefs.getBool('vision_iptv_exo') ?? true;
      _useEpgNames = prefs.getBool('vision_iptv_use_epg_names') ?? false;
      _quickStartSetting = prefs.getBool('vision_iptv_quick_start') ?? true;
      _showLoadingIndicator = prefs.getBool('vision_iptv_show_loading_indicator') ?? false;
      _listRefreshEntry = prefs.getBool('vision_iptv_list_refresh_entry') ?? true;
      _epgRefreshEntry = prefs.getBool('vision_iptv_epg_refresh_entry') ?? true;
      _listRefreshHours = _refreshHours(prefs,false); _epgRefreshHours = _refreshHours(prefs,true);
      _settingsHls = prefs.getBool('vision_iptv_force_hls') ?? false;
      _settingsTunnel = prefs.getBool('vision_iptv_tunneling') ?? false;
      _settingsPassthrough = prefs.getBool('vision_iptv_passthrough') ?? false;
      _settingsAfr = prefs.getBool('vision_iptv_afr') ?? false;
      _settingsBuffer = prefs.getString('vision_iptv_buffer') ?? 'minimum';
      _settingsSection = null;
      _settingsIndex = 0;
      _settingsOpen = true;
    });
  }

  void _closeSettings() {
    if (_applyingLists) return;
    if (_settingsSection != null) { _leaveSettingsSection(); return; }
    if (_listsDirty) { unawaited(_applyListChanges()); return; }
    setState(() { _settingsOpen = false; if (_settingsDirty) _menuStatus = 'Ajustes guardados'; });
    _playerFocus.requestFocus();
  }

  Future<void> _applyListChanges({bool keepSettings = false}) async {
    if (_applyingLists || _switching) return;
    _pendingAutoChannels = null;
    setState(() { _applyingLists = true; _menuStatus = 'Aplicando listas…'; });
    try {
      final playing = _channel;
      final selected = widget.channels[_highlightIndex];
      final group = _selectedGroup;
      final next = await widget.onReloadLists(Set.of(_refreshListIds));
      if (!mounted || _exiting) return;
      if (next == null) { setState(() => _menuStatus = 'No se pudieron aplicar las listas'); return; }
      if (next.isEmpty) { await _exitIptv(); return; }
      final playingIndex = next.indexWhere((c) => c.favoriteId == playing.favoriteId && c.url == playing.url && (!widget.isHidden(c) || widget.isFavorite(c)));
      final firstVisible = next.indexWhere((c) => !widget.isHidden(c) || widget.isFavorite(c));
      final retainedIndex = next.indexWhere((c) => c.favoriteId == playing.favoriteId && c.url == playing.url);
      final selectedIndex = next.indexWhere((c) => c.favoriteId == selected.favoriteId);
      setState(() {
        widget.channels..clear()..addAll(next);
        _rebuildChannelIndices();
        _groupIndex = _groups.indexOf(group);
        if (_groupIndex < 0) _groupIndex = 0;
        _channelIndex = playingIndex >= 0 ? playingIndex : firstVisible >= 0 ? firstVisible : retainedIndex >= 0 ? retainedIndex : 0;
        _highlightIndex = selectedIndex >= 0 ? selectedIndex : _channelIndex;
        if (_verticalGuide) { final vr=_verticalRows; _verticalChannelIndex=vr.contains(_channelIndex)?_channelIndex:vr.isNotEmpty?vr.first:_channelIndex; _syncVerticalProgramme(reset:true); }
        final rows = _visibleIndices;
        if (rows.isNotEmpty && !rows.contains(_highlightIndex)) _highlightIndex = rows.first;
        _timeShift = 0; _programmeIndex = -1; _stepProgramme(0);
        _catalogError = null;
        _listsDirty = false; _refreshListIds.clear(); if (!keepSettings) _settingsOpen = false;
        _menuStatus = widget.listError() ?? 'Listas actualizadas';
      });
      if (playingIndex < 0 && firstVisible >= 0 && _tuned && _player != null) {
        _failed = true;
        await _switchChannel(_channelIndex);
      }
      _scrollPreview(); _scrollGroup(); if (_verticalGuide) _scrollVerticalBoth(); _scheduleResize();
    } catch (_) { if (mounted) setState(() => _menuStatus = 'No se pudieron aplicar las listas'); }
    finally { if (mounted) { setState(() => _applyingLists = false); _playerFocus.requestFocus(); } }
  }

  List<String> get _settingKeys {
    switch (_settingsSection) {
      case 'section_lists': return ['lists','list_refresh_entry','list_refresh_hours','back'];
      case 'section_guide': return ['epg','epg_refresh_entry','epg_refresh_hours','epg_updated','refresh','back'];
      case 'section_appearance': return ['logos','epg_names','banner','loading_indicator','back'];
      case 'section_playback': return ['player',if (_settingsExo) ...['format','tunnel'] else 'buffer','passthrough','afr','back'];
      case 'section_behavior': return ['quick_start','discover_row','back'];
      case 'section_backup': return ['backup','restore','back'];
      default: return [..._settingsSections,'back'];
    }
  }

  Future<String?> _askListField(String label, String initial, {required bool isUrl, bool secret = false}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(context: context, barrierColor: Colors.black26, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF242A36), title: Text(label),
      content: SizedBox(width: 420, child: TextField(controller: controller, autofocus: true,
        keyboardType: TextInputType.text, obscureText: secret, autocorrect: !secret, enableSuggestions: !secret, textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.pop(ctx, v))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Guardar')),
      ],
    ));
    unawaited(Future<void>.delayed(const Duration(milliseconds: 350), controller.dispose));
    return result;
  }

  Future<void> _refreshListNow(Map<String,String> item) async {
    if (!mounted || _applyingLists) return;
    final id = item['id']!;
    _refreshListIds.add(id); _listsDirty = true;
    final done = ValueNotifier<bool>(false);
    final task = _applyListChanges(keepSettings: true).whenComplete(() { done.value = true; });
    await showDialog<void>(context: context, barrierDismissible: false, builder: (ctx) => ValueListenableBuilder<bool>(
      valueListenable: done, builder: (_, finished, __) => PopScope(canPop: finished,
        child: ValueListenableBuilder<Map<String,_ListStatus>>(valueListenable: widget.listStatuses, builder: (_, states, __) {
          final status = states[id];
          return AlertDialog(backgroundColor: const Color(0xFF1B202A), title: Text(item['name'] ?? 'Actualizar lista'),
            content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(status?.label ?? 'Conectando…'),
              if (!finished) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
              if (finished && status != null && status.vod > 0) Text('${status.vod} VOD descartados'),
            ])),
            actions: [TextButton(autofocus: finished, style: _iptvDialogButtonStyle, onPressed: finished ? () => Navigator.pop(ctx) : null, child: const Text('Cerrar'))]);
        }))));
    await task;
    done.dispose();
  }

  ButtonStyle get _listPanelButton => ButtonStyle(
    alignment: Alignment.centerLeft,
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal:14,vertical:8)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius:BorderRadius.circular(8))),
    backgroundColor: WidgetStateProperty.resolveWith((states)=>states.contains(WidgetState.focused)?const Color(0xFF90CAF9):const Color(0xFF242A36)),
    foregroundColor: WidgetStateProperty.resolveWith((states)=>states.contains(WidgetState.focused)?const Color(0xFF10151D):Colors.white),
  );

  Widget _listEditorRow(String label,String value,VoidCallback action,{IconData icon=Icons.edit,FocusNode? focusNode,bool autofocus=false}) =>
    Padding(padding:const EdgeInsets.only(bottom:5),child:TextButton(
      focusNode:focusNode,autofocus:autofocus,style:_listPanelButton,onPressed:action,
      child:Row(children:[Icon(icon,size:18),const SizedBox(width:12),Expanded(child:Text(label,maxLines:1,overflow:TextOverflow.ellipsis)),Flexible(child:Text(value,maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.end,style:const TextStyle(fontSize:13))),const SizedBox(width:10),const Icon(Icons.chevron_right,size:18)])));

  Future<void> _manageLists() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lists = _iptvLists(prefs);
    var last = -1;
    while (mounted) {
      final action = await showDialog<int>(context:context,barrierColor:Colors.black26,builder:(ctx)=>Dialog(
        backgroundColor:const Color(0xFF1B202A),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14)),
        child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:620),child:Padding(padding:const EdgeInsets.all(18),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Row(children:[const Icon(Icons.list_alt,color:Color(0xFF90CAF9)),const SizedBox(width:10),const Expanded(child:Text('Listas IPTV',style:TextStyle(fontSize:21,fontWeight:FontWeight.bold))),Text('${lists.where((l)=>l['active']=='true').length} activas · ${lists.length} listas',style:const TextStyle(fontSize:12,color:Colors.white70))]),
          const SizedBox(height:12),
          _listEditorRow('Añadir nueva lista','',()=>Navigator.pop(ctx,-1),icon:Icons.add,autofocus:last<0||last>=lists.length),
          Flexible(child:ListView.builder(shrinkWrap:true,itemCount:lists.length,itemBuilder:(_,i)=>ValueListenableBuilder<Map<String,_ListStatus>>(valueListenable:widget.listStatuses,builder:(_,states,__){
            final item=lists[i],active=item['active']=='true',status=states[item['id']];
            final updated=status?.updated;
            final info=active?status?.label??'Pendiente de carga':'Inactiva';
            return Padding(padding:const EdgeInsets.only(bottom:6),child:TextButton(autofocus:last==i,style:_listPanelButton,onPressed:()=>Navigator.pop(ctx,i),child:Row(children:[
              Icon(active?Icons.check_circle:Icons.pause_circle_outline,size:23),const SizedBox(width:12),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Row(children:[Expanded(child:Text(item['name']??'Lista IPTV',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:16,fontWeight:FontWeight.bold))),Text(_isXtream(item)?'Xtream Codes':'M3U',style:const TextStyle(fontSize:12))]),
                const SizedBox(height:3),Text('${active?'Activa · ':''}$info',maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:13)),
                if(active&&updated!=null) Text('Actualizada: ${updated.day}/${updated.month}/${updated.year} ${_clock(updated)}',style:const TextStyle(fontSize:11)),
                if(active&&status!=null&&status.vod>0) Text('${status.vod} VOD descartados',style:const TextStyle(fontSize:11)),
              ])),const SizedBox(width:12),const Icon(Icons.chevron_right,size:20)
            ])));
          }))),
          const SizedBox(height:8),Align(alignment:Alignment.centerRight,child:TextButton(style:_iptvDialogButtonStyle,onPressed:()=>Navigator.pop(ctx),child:const Text('Cerrar'))),
        ])))));
      if (!mounted || action==null) break;
      last=action;
      await Future<void>.delayed(const Duration(milliseconds:200));
      if (!mounted) return;
      await _editListPanel(prefs,lists,action);
    }
    if(mounted){_playerFocus.requestFocus();_scheduleResize();}
  }

  Future<void> _editListPanel(SharedPreferences prefs,List<Map<String,String>> lists,int index) async {
    final fresh=index<0;
    final original=fresh?<String,String>{}:Map<String,String>.of(lists[index]);
    final draft=<String,String>{'type':'m3u','active':'true','excludeVod':'true',...original};
    final nodes=<String,FocusNode>{};
    FocusNode node(String key)=>nodes.putIfAbsent(key,()=>FocusNode());
    String error='';
    bool busy=false;
    String configured(String key)=>(draft[key]??'').isEmpty?'Sin configurar':'••••••••';
    String? validate(){
      final uri=Uri.tryParse(draft['url']??'');
      if(uri==null||!['http','https'].contains(uri.scheme)||uri.host.isEmpty)return 'Introduce una URL válida.';
      if(_isXtream(draft)&&((draft['user']??'').isEmpty||(draft['password']??'').isEmpty))return 'Introduce el usuario y la contraseña.';
      final epg=draft['epg']??'';
      if(epg.isNotEmpty){final u=Uri.tryParse(epg);if(u==null||!['http','https'].contains(u.scheme)||u.host.isEmpty)return 'Introduce una URL EPG válida o déjala vacía.';}
      if(lists.asMap().entries.any((e)=>e.key!=index&&_playlistKey(e.value)==_playlistKey(draft)))return 'La lista ya existe.';
      return null;
    }
    final result=await showDialog<String>(context:context,barrierDismissible:false,builder:(ctx)=>StatefulBuilder(builder:(ctx,update){
      Future<void> edit(String key,String label,{bool url=false,bool secret=false}) async {
        if(busy)return;busy=true;
        final value=await _askListField(label,draft[key]??'',isUrl:url,secret:secret);
        busy=false;if(!ctx.mounted)return;
        if(value!=null)update((){draft[key]=key=='password'?value:value.trim();error='';});
        node(key).requestFocus();
      }
      Widget field(String key,String label,String value,VoidCallback action,{IconData icon=Icons.edit,bool autofocus=false})=>_listEditorRow(label,value,action,icon:icon,focusNode:node(key),autofocus:autofocus);
      return Dialog(backgroundColor:const Color(0xFF1B202A),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14)),child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:620),child:Padding(padding:const EdgeInsets.all(18),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Text(fresh?'Nueva lista IPTV':'Editar lista IPTV',style:const TextStyle(fontSize:21,fontWeight:FontWeight.bold)),
        if(!fresh) Padding(padding:const EdgeInsets.only(top:4),child:Text(_isXtream(draft)?'Xtream Codes':'M3U',style:const TextStyle(color:Color(0xFF90CAF9),fontSize:13))),
        const SizedBox(height:12),
        Flexible(child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          field('name','Nombre',(draft['name']??'').isEmpty?'Sin configurar':draft['name']!,()=>unawaited(edit('name','Nombre de la lista')),autofocus:true),
          if(fresh)field('type','Tipo',_isXtream(draft)?'Xtream Codes':'M3U',()=>update((){draft['type']=_isXtream(draft)?'m3u':'xc';if(_isXtream(draft))draft['excludeVod']='true';error='';}),icon:Icons.swap_horiz),
          field('url',_isXtream(draft)?'URL servidor':'URL M3U',configured('url'),()=>unawaited(edit('url',_isXtream(draft)?'URL del servidor Xtream':'URL M3U',url:true))),
          if(_isXtream(draft))...[
            field('user','Usuario',configured('user'),()=>unawaited(edit('user','Usuario',secret:true))),
            field('password','Contraseña',configured('password'),()=>unawaited(edit('password','Contraseña',secret:true))),
          ],
          field('epg','URL EPG',(draft['epg']??'').isEmpty?'Automática / predeterminada':'Configurada',()=>unawaited(edit('epg','URL EPG (vacía = predeterminada)',url:true))),
          field('active','Estado',draft['active']=='true'?'Activa':'Inactiva',()=>update(()=>draft['active']=draft['active']=='true'?'false':'true'),icon:Icons.power_settings_new),
          if(!_isXtream(draft))field('excludeVod','Excluir VOD',_excludeVod(draft)?'Sí':'No',()=>update(()=>draft['excludeVod']=_excludeVod(draft)?'false':'true'),icon:Icons.video_library),
          if(!fresh)...[
            field('groups','Gestionar grupos','${_hiddenGroups(draft).length} ocultos',()async{
              if(busy)return;busy=true;
              final hidden=await _manageListGroups(draft,widget.listGroups(original));
              busy=false;if(!ctx.mounted)return;
              if(hidden!=null)update(()=>draft['hiddenGroups']=jsonEncode(hidden.toList()));
              node('groups').requestFocus();
            },icon:Icons.folder_open),
            if(original['active']=='true')field('refresh','Actualizar lista','En segundo plano',(){
              widget.queueManualList(original['id']!);
              update(()=>error='Actualización en segundo plano solicitada.');
            },icon:Icons.refresh),
            field('delete','Eliminar lista','',()async{
              final yes=await showDialog<bool>(context:ctx,builder:(confirm)=>AlertDialog(title:const Text('Eliminar lista IPTV'),content:Text('¿Eliminar ${original['name']??'esta lista'}?'),actions:[
                TextButton(autofocus:true,style:_iptvDialogButtonStyle,onPressed:()=>Navigator.pop(confirm,false),child:const Text('Cancelar')),
                TextButton(style:_iptvDialogButtonStyle,onPressed:()=>Navigator.pop(confirm,true),child:const Text('Eliminar')),
              ]));
              if(ctx.mounted&&yes==true)Navigator.pop(ctx,'delete');
              else if(ctx.mounted)node('delete').requestFocus();
            },icon:Icons.delete_outline),
          ],
        ]))),
        if(error.isNotEmpty) Padding(padding:const EdgeInsets.only(top:5),child:Text(error,style:const TextStyle(color:Color(0xFF90CAF9),fontSize:12))),
        const SizedBox(height:8),
        Row(mainAxisAlignment:MainAxisAlignment.end,children:[
          TextButton(style:_iptvDialogButtonStyle,onPressed:()=>Navigator.pop(ctx),child:const Text('Cancelar')),
          const SizedBox(width:8),
          TextButton(style:_iptvDialogButtonStyle,onPressed:(){final problem=validate();if(problem!=null){update(()=>error=problem);return;}Navigator.pop(ctx,'save');},child:Text(fresh?'Guardar lista':'Guardar cambios')),
        ]),
      ]))));
    }));
    unawaited(Future<void>.delayed(const Duration(milliseconds:350),(){for(final n in nodes.values)n.dispose();}));
    if(!mounted||result==null)return;
    if(result=='delete'){lists.removeAt(index);await _saveLists(prefs,lists);return;}
    if(result!='save')return;
    if((draft['name']??'').isEmpty)draft['name']='Lista IPTV';
    if(!_isXtream(draft)){draft.remove('user');draft.remove('password');}
    draft['id']??=_playlistKey(draft);
    if(!fresh&&mapEquals(original,draft))return;
    // Legacy lists may not store explicit defaults; saving unchanged must not reload.
    if(!fresh&&mapEquals(<String,String>{'type':'m3u','active':'true','excludeVod':'true',...original},draft))return;
    final needsDownload=fresh||_playlistKey(original)!=_playlistKey(draft);
    if(fresh){lists.add(draft);}else{lists[index]=draft;}
    await _saveLists(prefs,lists);
    if(draft['active']=='true'&&needsDownload)await _refreshListNow(draft);
  }

  Future<Set<String>?> _manageListGroups(Map<String,String> item, List<String> groups) async {
    if (groups.isEmpty) {
      await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Grupos de IPTV'), content: const Text('La lista todavía no tiene grupos cargados. Actívala y sal de ajustes para descargarla.'),
        actions: [TextButton(autofocus: true, style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx), child: const Text('Aceptar'))]));
      return null;
    }
    final hidden = _hiddenGroups(item);
    return showDialog<Set<String>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
      backgroundColor: const Color(0xFF1B202A),
      title: Text('Gestionar grupos · ${item['name']}'),
      content: SizedBox(width: 460, height: 320, child: Column(children: [
        Text('${groups.where((g) => !hidden.contains(g)).length} de ${groups.length} grupos visibles'),
        Row(children: [
          Expanded(child: TextButton(autofocus: true, style: _iptvDialogButtonStyle, onPressed: () => update(() => hidden.clear()), child: const Text('Mostrar todos'))),
          Expanded(child: TextButton(style: _iptvDialogButtonStyle, onPressed: () => update(() => hidden.addAll(groups)), child: const Text('Ocultar todos'))),
        ]),
        Expanded(child: ListView(children: [for (final group in groups) TextButton.icon(style: _iptvDialogButtonStyle, icon: Icon(hidden.contains(group) ? Icons.check_box_outline_blank : Icons.check_box),
            label: Text(group, maxLines: 1, overflow: TextOverflow.ellipsis),
            onPressed: () => update(() { if (!hidden.remove(group)) hidden.add(group); }))])),
      ])),
      actions: [
        TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx, hidden), child: const Text('Guardar')),
      ],
    )));
  }

  Future<void> _saveLists(SharedPreferences prefs, List<Map<String,String>> lists) async {
    await prefs.setString('vision_iptv_lists', jsonEncode(lists));
    final active = lists.where((l) => l['active'] == 'true').toList();
    final m3u = active.where((l) => !_isXtream(l)).toList();
    await prefs.setString('vision_iptv_url', m3u.isEmpty ? '' : m3u.first['url'] ?? '');
    if (mounted) setState(() { _settingsUrl = active.isEmpty ? '' : active.first['url'] ?? ''; _listsDirty = true; _menuStatus = '${active.length} listas activas'; });
  }

  Future<void> _editSettingsUrl(bool epg) async {
    final controller = TextEditingController(text: epg ? _settingsEpg : _settingsUrl);
    final result = await showDialog<String>(context: context, barrierColor: Colors.black26, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF242A36),
      title: Text(epg ? 'EPG predeterminada (XMLTV)' : 'Lista IPTV M3U'),
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
      await prefs.setString(epg ? 'vision_iptv_default_epg' : 'vision_iptv_url', value);
      if (mounted) setState(() { if (epg) { _settingsEpg = value; } else { _settingsUrl = value; } _listsDirty = true; });
    }
    if (mounted) { _playerFocus.requestFocus(); _scheduleResize(); }
  }

  Future<void> _activateSetting() async {
    final key = _settingKeys[_settingsIndex];
    if (key == 'section_remote_help') { await _showIptvRemoteHelp(context); return; }
    if (_settingsSections.contains(key)) { setState(() { _settingsSection = key; _settingsIndex = 0; }); _resetSettingsScroll(); return; }
    if (key == 'back') { _closeSettings(); return; }
    if (key == 'discover_row') { final prefs = await SharedPreferences.getInstance(); if (!mounted) return; setState(() => _discoverRow = !(prefs.getBool(_discoverIptvPref) ?? true)); await prefs.setBool(_discoverIptvPref, _discoverRow); visionDiscoverIptvChanged.value++; return; }
    if (key == 'lists') { await _manageLists(); return; }
    if (key == 'epg_updated') return;
    if (key == 'backup' || key == 'restore') { await _configurationBackup(key == 'restore'); return; }
    if (key == 'banner') { final prefs = await SharedPreferences.getInstance(); if (!mounted) return; setState(() => _bannerSeconds = _bannerChoices[(_bannerChoices.indexOf(_bannerSeconds) + 1) % _bannerChoices.length]); await prefs.setInt('vision_iptv_banner_seconds', _bannerSeconds); return; }
    if (key == 'm3u' || key == 'epg') { await _editSettingsUrl(key == 'epg'); return; }
    if (key == 'refresh') {
      widget.queueManualGuide();
      setState(() => _menuStatus = 'Actualización EPG en segundo plano solicitada');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || !_settingsOpen) return;
    setState(() {
      _settingsDirty = true;
      switch (key) {
        case 'player': _settingsExo = !_settingsExo; break;
        case 'passthrough': _settingsPassthrough = !_settingsPassthrough; break;
        case 'afr': _settingsAfr = !_settingsAfr; break;
        case 'logos': _logoSource = _logoSource == 'epg' ? 'm3u' : 'epg'; break;
        case 'epg_names': _useEpgNames = !_useEpgNames; break;
        case 'quick_start': _quickStartSetting = !_quickStartSetting; break;
        case 'loading_indicator': _showLoadingIndicator = !_showLoadingIndicator; break;
        case 'list_refresh_entry': _listRefreshEntry = !_listRefreshEntry; break;
        case 'epg_refresh_entry': _epgRefreshEntry = !_epgRefreshEntry; break;
        case 'list_refresh_hours': _listRefreshHours = _listRefreshChoices[(_listRefreshChoices.indexOf(_listRefreshHours)+1)%_listRefreshChoices.length]; break;
        case 'epg_refresh_hours': _epgRefreshHours = _epgRefreshChoices[(_epgRefreshChoices.indexOf(_epgRefreshHours)+1)%_epgRefreshChoices.length]; break;
        case 'format': _settingsHls = !_settingsHls; break;
        case 'tunnel': _settingsTunnel = !_settingsTunnel; break;
        case 'buffer': _settingsBuffer = _settingsBuffer == 'minimum' ? 'small' : _settingsBuffer == 'small' ? 'normal' : 'minimum'; break;
      }
      _settingsIndex = _settingsIndex.clamp(0, _settingKeys.length - 1).toInt();
    });
    switch (key) {
      case 'player': await prefs.setBool('vision_iptv_exo', _settingsExo); break;
      case 'passthrough': await prefs.setBool('vision_iptv_passthrough', _settingsPassthrough); break;
      case 'afr': await prefs.setBool('vision_iptv_afr', _settingsAfr); break;
      case 'logos': await prefs.setString('vision_iptv_logo_source', _logoSource); break;
      case 'epg_names': await prefs.setBool('vision_iptv_use_epg_names', _useEpgNames); break;
      case 'quick_start': await prefs.setBool('vision_iptv_quick_start', _quickStartSetting); break;
      case 'loading_indicator': await prefs.setBool('vision_iptv_show_loading_indicator', _showLoadingIndicator); break;
      case 'list_refresh_entry': await prefs.setBool('vision_iptv_list_refresh_entry',_listRefreshEntry); break;
      case 'epg_refresh_entry': await prefs.setBool('vision_iptv_epg_refresh_entry',_epgRefreshEntry); break;
      case 'list_refresh_hours': await prefs.setInt('vision_iptv_list_refresh_hours',_listRefreshHours); break;
      case 'epg_refresh_hours': await prefs.setInt('vision_iptv_epg_refresh_hours',_epgRefreshHours); break;
      case 'format': await prefs.setBool('vision_iptv_force_hls', _settingsHls); break;
      case 'tunnel': await prefs.setBool('vision_iptv_tunneling', _settingsTunnel); break;
      case 'buffer': await prefs.setString('vision_iptv_buffer', _settingsBuffer); break;
    }
  }

  Future<File> _iptvBackupFile(SharedPreferences prefs, {required bool restore}) async {
    final saved = prefs.getString('vision_iptv_backup_path');
    final fallback = File('${(await getApplicationDocumentsDirectory()).path}/IPTV_backup.json');
    final external = Platform.isAndroid ? await getExternalStorageDirectory() : null;
    final files = [if (saved != null) File(saved), if (Platform.isAndroid) File('/sdcard/Download/PlezyVision/IPTV_backup.json'), if (external != null) File('${external.path}/IPTV_backup.json'), fallback];
    for (final file in files) {
      try {
        if (restore) { if (await file.exists()) return file; continue; }
        await file.parent.create(recursive: true);
        final probe = File('${file.path}.probe');
        await probe.writeAsString(''); await probe.delete();
        return file;
      } catch (_) {}
    }
    return fallback;
  }

  Future<void> _configurationBackup(bool restore) async {
    _externalPicker = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final backup = await _iptvBackupFile(prefs, restore: restore);
      if (!restore) {
        if (await backup.exists()) {
          if (!mounted) return;
          final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1B202A), title: const Text('Sobrescribir copia de seguridad'),
            content: Text(backup.path), actions: [
              TextButton(autofocus: true, style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx,false), child: const Text('Cancelar')),
              TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx,true), child: const Text('Guardar'))]));
          if (yes != true) return;
        }
        final values = <String, dynamic>{for (final key in prefs.getKeys()) if (key.startsWith('vision_iptv_')) key: prefs.get(key)};
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode({'version': 1, 'settings': values})));
        final temp = File('${backup.path}.tmp');
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(backup.path);
        await prefs.setString('vision_iptv_backup_path', backup.path);
        if (mounted) setState(() => _menuStatus = 'Copia guardada: ${backup.path}');
        return;
      }
      if (!await backup.exists()) { if (mounted) setState(() => _menuStatus = 'No existe copia de seguridad: ${backup.path}'); return; }
      if (await backup.length() > 10 * 1024 * 1024) throw const FormatException('Invalid backup');
      final bytes = await backup.readAsBytes();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map || decoded['version'] != 1 || decoded['settings'] is! Map) throw const FormatException('Invalid backup');
      final values = Map<String, dynamic>.from(decoded['settings'] as Map);
      if (values.isEmpty || values.entries.any((e) => !e.key.startsWith('vision_iptv_') ||
          !(e.value is String || e.value is bool || e.value is int || e.value is List && (e.value as List).every((v) => v is String)))) throw const FormatException('Invalid settings');
      if (!mounted) return;
      final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B202A), title: const Text('Restaurar configuración IPTV'),
        content: const Text('Se sustituirán las listas, favoritos y ajustes actuales.'),
        actions: [TextButton(style: _iptvDialogButtonStyle, autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx, true), child: const Text('Restaurar'))]));
      if (yes != true || !mounted) return;
      for (final key in prefs.getKeys().where((k) => k.startsWith('vision_iptv_'))) { await prefs.remove(key); }
      for (final e in values.entries) {
        final v = e.value;
        if (v is String) { await prefs.setString(e.key, v); }
        else if (v is bool) { await prefs.setBool(e.key, v); }
        else if (v is int) { await prefs.setInt(e.key, v); }
        else if (v is List) { await prefs.setStringList(e.key, v.cast<String>()); }
      }
      await prefs.setString('vision_iptv_backup_path', backup.path);
      if (mounted) await _exitIptv();
    } catch (_) { if (mounted) setState(() => _menuStatus = 'No se pudo completar la copia o restauración'); }
    finally { _externalPicker = false; }
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
    final labels = <String, String>{..._settingsSectionLabels, 'discover_row':'Mostrar TV en vivo en Discover', 'loading_indicator':'Mostrar indicador de carga', 'list_refresh_entry':'Actualizar al iniciar TV en vivo','epg_refresh_entry':'Actualizar al iniciar TV en vivo','list_refresh_hours':'Intervalo de actualización','epg_refresh_hours':'Intervalo de actualización','epg_updated':'Última actualización EPG', 'm3u': 'Lista M3U activa', 'epg': 'EPG predeterminada', 'lists': 'Listas IPTV', 'quick_start': 'Inicio rápido en último canal', 'banner': 'Duración barra de información', 'player': 'Reproductor IPTV', 'format': 'Formato', 'tunnel': 'Tunneling', 'buffer': 'Búfer MPV', 'passthrough': 'Audio passthrough', 'afr': 'AFR', 'logos': 'Origen de logotipos', 'epg_names': 'Renombrar canales según EPG', 'backup': 'Copia de seguridad', 'restore': 'Restaurar configuración', 'refresh': 'Actualizar programación', 'back': 'Volver al menú'};
    final values = <String, String>{'discover_row':_discoverRow ? 'Sí' : 'No', 'section_lists':'Listas y grupos', 'section_guide':'EPG y actualización', 'section_appearance':'Aspecto e información', 'section_playback':'Motor y opciones de vídeo/audio', 'section_behavior':'Arranque', 'section_backup':'Guardar y restaurar', 'section_remote_help':'Tutorial', 'loading_indicator':_showLoadingIndicator ? 'Sí' : 'No', 'list_refresh_entry':_listRefreshEntry?'Sí':'No','epg_refresh_entry':_epgRefreshEntry?'Sí':'No','list_refresh_hours':_refreshLabel(_listRefreshHours),'epg_refresh_hours':_refreshLabel(_epgRefreshHours),'epg_updated':widget.epgUpdatedLabel(), 'm3u': _settingsUrl.isEmpty ? 'Sin configurar' : 'Configurada', 'epg': _settingsEpg.isEmpty ? 'Automática desde M3U' : 'Manual', 'lists': 'Gestionar', 'quick_start': _quickStartSetting ? 'Sí' : 'No', 'banner': _bannerSeconds == 0 ? 'Permanente' : '${_bannerSeconds} s', 'player': _settingsExo ? 'ExoPlayer' : 'MPV', 'format': _settingsHls ? 'HLS' : 'Auto', 'tunnel': _settingsTunnel ? 'Sí' : 'No', 'buffer': _settingsBuffer == 'minimum' ? 'Mínimo (0)' : _settingsBuffer == 'small' ? 'Pequeño' : 'Normal', 'passthrough': _settingsPassthrough ? 'Sí' : 'No', 'afr': _settingsAfr ? 'Sí' : 'No', 'logos': _logoSource == 'epg' ? 'EPG' : 'M3U', 'epg_names': _useEpgNames ? 'Sí' : 'No', 'backup': '', 'restore': '', 'refresh': widget.guideStatus(), 'back': ''};
    final icons = <String, IconData>{'discover_row':Icons.tv, 'section_lists':Icons.list, 'section_guide':Icons.calendar_today, 'section_appearance':Icons.monitor, 'section_playback':Icons.play_circle_outline, 'section_behavior':Icons.flash_on, 'section_backup':Icons.save, 'section_remote_help':Icons.help_outline, 'loading_indicator':Icons.hourglass_empty, 'list_refresh_entry':Icons.flash_on,'epg_refresh_entry':Icons.flash_on,'list_refresh_hours':Icons.timer,'epg_refresh_hours':Icons.timer,'epg_updated':Icons.calendar_today, 'm3u': Icons.list, 'epg': Icons.calendar_today, 'lists': Icons.playlist_add, 'quick_start': Icons.flash_on, 'banner': Icons.timer, 'player': Icons.play_circle_outline, 'format': Icons.video_settings, 'tunnel': Icons.settings_ethernet, 'buffer': Icons.memory, 'passthrough': Icons.volume_up, 'afr': Icons.monitor, 'logos': Icons.image, 'epg_names': Icons.edit, 'backup': Icons.save, 'restore': Icons.folder_open, 'refresh': Icons.refresh, 'back': Icons.arrow_back};
    final keys = _settingKeys;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF1B202A), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_settingsSection == null ? 'Ajustes IPTV' : 'Ajustes IPTV · ${_settingsSectionLabels[_settingsSection]}', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Expanded(child: ListView.builder(controller: _settingsScroll, itemExtent: 44, itemCount: keys.length, itemBuilder: (_, i) {
          final key = keys[i], focused = i == _settingsIndex;
          final fg = focused ? Colors.black : Colors.white;
          return Container(margin: const EdgeInsets.only(bottom: 4), padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: focused ? const Color(0xFF90CAF9) : const Color(0xFF242A36), borderRadius: BorderRadius.circular(7)),
            child: Row(children: [
              Icon(icons[key], size: 19, color: fg),
              const SizedBox(width: 10),
              Expanded(child: Text(key == 'back' && _settingsSection != null ? 'Volver a ajustes IPTV' : labels[key]!, maxLines:1,overflow:TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 14))),
              Text(values[key]!, style: TextStyle(color: focused ? Colors.black87 : Colors.white70, fontSize: 13)),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: fg, size: 18),
            ]));
        })),
        const SizedBox(height: 4),
        Text(_applyingLists ? 'Aplicando listas…' : _listsDirty ? 'Los cambios de listas se aplican al salir de ajustes' : (_settingsSection == null ? 'OK: abrir sección · Atrás: volver al menú' : 'OK: cambiar · Atrás: volver a ajustes'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
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
  Timer? _guidePageTimer;
  void _scheduleGuidePage() {
    _guidePageTimer?.cancel();
    _guidePageTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || _exiting) return;
      final rows = _verticalGuide ? _verticalRows : _visibleIndices;
      final selected = _verticalGuide ? (_verticalChannelIndex ?? _channelIndex) : _highlightIndex;
      final pos = rows.indexOf(selected);
      final start = (pos - 12).clamp(0, rows.length).toInt();
      final end = (start + 28).clamp(0, rows.length).toInt();
      final indices = _verticalGuide ? <int>{_channelIndex,selected, for (var i = start; i < end; i++) rows[i]} : <int>{_channelIndex,_highlightIndex, for (var i = start; i < end; i++) rows[i]};
      unawaited(widget.onGuidePage([for (final i in indices) if (i >= 0 && i < widget.channels.length) widget.channels[i]]));
    });
  }
  void _guideChanged() {
    if (!mounted) return;
    setState(() {
      if (_verticalGuide) _syncVerticalProgramme();
      if (_preview) {
        final at = _guideAnchor ?? DateTime.now();
        _programmeIndex = _programmes(_highlightIndex).indexWhere((p) => !at.isBefore(p.start) && at.isBefore(p.stop));
      }
      if (_bannerProgramme != null) {
        final old = _bannerProgramme!;
        final entries = _guide[widget.epgId(_channel)] ?? const <_Programme>[];
        final i = entries.indexWhere((p) => p.start == old.start && p.stop == old.stop);
        _bannerProgramme = i < 0 ? null : entries[i];
      }
    });
    if (_verticalGuide) _scrollVertical(_verticalProgrammesScroll,_verticalProgrammeIndex,_verticalProgrammeExtent);
  }
  void _selectGroup(int index) {
    final visual = [1,0, for (var i = 2; i < _groups.length; i++) i];
    final target = visual[(visual.indexOf(_groupIndex) + (index - _groupIndex)).clamp(0, visual.length - 1).toInt()];
    index = target;
    if (index == _groupIndex) return;
    setState(() { _recentOnly = false; _groupIndex = index.clamp(0, _groups.length - 1).toInt(); final rows = _visibleIndices; if (rows.isNotEmpty) _highlightIndex = rows.first; _programmeIndex = -1; _guideAnchor = null; _timeShift = 0; if (rows.isNotEmpty) _stepProgramme(0); });
    _scrollPreview();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _groupScroll.hasClients) { final p = _groupScroll.position; _groupScroll.jumpTo(((_groupIndex - 2) * 38.0 - p.viewportDimension / 2 + 19).clamp(0.0, p.maxScrollExtent).toDouble()); } });
  }
  void _moveRow(int delta, {bool wrap = true}) {
    final rows = _visibleIndices;
    if (rows.isEmpty) return;
    final position = rows.indexOf(_highlightIndex);
    if (!wrap && position >= 0 && (position + delta < 0 || position + delta >= rows.length)) return;
    final now = DateTime.now();
    final selected = _selectedProgramme;
    final current = selected != null ? !now.isBefore(selected.start) && now.isBefore(selected.stop) : _guideAnchor == null && _timeShift == 0;
    final selectedTime = current ? now : (_guideAnchor ?? selected?.start ?? _windowStart);
    setState(() {
      final pos = rows.indexOf(_highlightIndex);
      final row = pos < 0 ? (delta < 0 ? rows.length - 1 : 0) : (pos + delta + rows.length) % rows.length;
      _highlightIndex = rows[row];
      final programmes = _programmes(_highlightIndex);
      _guideAnchor = current ? null : selectedTime;
      _programmeIndex = programmes.indexWhere((p) => !selectedTime.isBefore(p.start) && selectedTime.isBefore(p.stop));
    });
    _scrollPreview();
  }
  bool _isOnAir(_Programme p) { final now=DateTime.now(); return !now.isBefore(p.start)&&now.isBefore(p.stop); }
  Future<void> _confirmGuideSelection() async {
    final p=_programmeHasFocus?_selectedProgramme:null;
    if(p!=null&&!_isOnAir(p)){await _withDialog(_programmeContext);return;}
    await _confirmGuide();
  }
  KeyEventResult _guideOk(KeyEvent event, {required bool vertical}) {
    if(event is KeyDownEvent){
      _guideSelectDown=true;_favoriteLong=false;_favoriteHold?.cancel();
      _favoriteHold=Timer(const Duration(milliseconds:600),(){
        if (!mounted || !_guideSelectDown || _dialogBusy || _settingsOpen || _exiting) return;
        final programme = _programmeHasFocus;
        final channel = vertical ? _verticalGuide && _verticalColumn == 0 && _verticalRows.isNotEmpty : _preview && !_groupFocus && _visibleIndices.isNotEmpty;
        if (!programme && !channel) return;
        _favoriteLong = true;
        _blockedGuideOk = event.physicalKey;
        unawaited(_withDialog(programme ? _programmeContext : _channelContext));
      });
    }
    if(event is KeyUpEvent){
      _favoriteHold?.cancel();
      final pressed=_guideSelectDown,long=_favoriteLong;
      _guideSelectDown=false;_favoriteLong=false;
      if(pressed){
        if (!long) {
          if(vertical){unawaited(_confirmVertical());}
          else{unawaited(_confirmGuideSelection());}
        }
      }
    }
    return KeyEventResult.handled;
  }
  Future<void> _confirmGuide() async {
    if (_groupFocus) { if (_toggleGroupHeader()) return; if (_visibleIndices.isNotEmpty) setState(() { _groupFocus = false; _programmeIndex = -1; _stepProgramme(0); }); return; }
    if (_visibleIndices.isEmpty || _switching) return;
    if (!_tuned) {
      setState(() { _channelIndex = _highlightIndex; _tuned = true; _switching = true; _pendingTuneBanner = true; _showName = false; });
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
    if (_zooming || value == _preview) return;
    if (_player != null && _ready && !_failed && !_switching) { unawaited(_animatePreview(value)); return; }
    _finishPreview(value);
  }

  void _finishPreview(bool value) {
    _timer?.cancel();
    final showTune = !value && _pendingTuneBanner;
    if (showTune) _pendingTuneBanner = false;
    setState(() { _zooming = false; _zoomRect = null; _bannerProgramme = null; _preview = value; _menuOpen = false; _showChannels = false; _highlightIndex = _channelIndex; _programmeIndex = -1; _inProgrammes = true; _timeShift = 0; _groupFocus = false; _showName = showTune; if (!_visibleIndices.contains(_channelIndex)) { _recentOnly = false; _groupIndex = 0; } if (value) _stepProgramme(0); });
    _scheduleResize();
    if (value) {
      _timer?.cancel();
      _scrollPreview();
    } else { _scheduleGuidePage(); if (_ready) unawaited(widget.onFullscreen(_channel)); if (showTune) _hideLater(); }
    _playerFocus.requestFocus();
  }
  Future<void> _animatePreview(bool value) async {
    final box = _videoKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) { _finishPreview(value); return; }
    final size = MediaQuery.sizeOf(context);
    final full = Offset.zero & size;
    const small = Rect.fromLTWH(20, 16, 288, 162);
    final start = _preview ? small : full, end = value ? small : full;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final player = _player;
    final channel = MethodChannel(player is PlayerAndroid ? 'com.plezy/exo_player' : 'com.plezy/mpv_player');
    final generation = ++_zoomGeneration;
    _timer?.cancel();
    setState(() { _zooming = true; _zoomRect = start; _showName = false; });
    final clock = Stopwatch()..start();
    try {
      while (mounted && !_exiting && generation == _zoomGeneration) {
        final t = (clock.elapsedMilliseconds / 250).clamp(0.0, 1.0).toDouble();
        final rect = Rect.lerp(start, end, Curves.easeInOut.transform(t))!;
        setState(() => _zoomRect = rect);
        await channel.invokeMethod('setIptvBounds', {'left': (rect.left * dpr).round(), 'top': (rect.top * dpr).round(), 'width': (rect.width * dpr).round(), 'height': (rect.height * dpr).round()});
        if (t >= 1) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } catch (_) {
      // Fall back to the normal instant resize if the native backend rejects intermediate bounds.
    }
    if (mounted && !_exiting && generation == _zoomGeneration) _finishPreview(value);
  }

  void _scrollPreview() {
    _scheduleGuidePage();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_preview || !_previewScroll.hasClients) return;
      final p = _previewScroll.position;
      _previewScroll.jumpTo((_visibleIndices.indexOf(_highlightIndex) * 54.0 - p.viewportDimension / 2 + 27).clamp(0.0, p.maxScrollExtent).toDouble());
    });
  }
  Future<void> _withDialog(Future<void> Function() action) async {
    if (_dialogBusy) return;
    _dialogBusy = true;
    _backHold?.cancel(); _backHold = null;
    _favoriteHold?.cancel(); _guideSelectDown = false;
    try { await action(); }
    finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _dialogBusy = false;
      if (mounted) {
        _playerFocus.requestFocus();
        if (_idleClosing) {
          _idleClosing = false;
          _returnFromConsultation();
        }
      }
    }
  }

  Future<void> _renameChannel(_Channel c) async {
    final controller = TextEditingController(text: _name(c));
    final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1B202A), title: const Text('Renombrar canal'),
      content: TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
      actions: [TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx, ''), child: const Text('Nombre original')),
        TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Guardar'))]));
    unawaited(Future<void>.delayed(const Duration(milliseconds: 350), controller.dispose));
    if (value == null || !mounted) return;
    final names = Map<String, dynamic>.from(widget.custom['names'] as Map? ?? {});
    if (value.trim().isEmpty || value.trim() == c.name) { names.remove(c.favoriteId); } else { names[c.favoriteId] = value.trim(); }
    setState(() => widget.custom['names'] = names);
    await _saveCustom();
  }

  Future<void> _chooseLogo(_Channel c) async {
    final choice = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1B202A), title: const Text('Origen del logotipo'),
      actions: [for (final entry in const {'': 'Predeterminado', 'epg': 'EPG', 'm3u': 'Lista M3U'}.entries)
        TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(ctx, entry.key), child: Text(entry.value))]));
    if (choice == null || !mounted) return;
    final logos = Map<String, dynamic>.from(widget.custom['logos'] as Map? ?? {});
    if (choice.isEmpty) { logos.remove(c.favoriteId); } else { logos[c.favoriteId] = choice; }
    setState(() => widget.custom['logos'] = logos);
    await _saveCustom();
  }

  Future<void> _toggleGuideFavorite(_Channel c) async {
    final vertical = _verticalGuide;
    final previous = vertical ? _verticalRows : _visibleIndices;
    final position = previous.indexOf(vertical ? _verticalSelected : _highlightIndex);
    await widget.onFavorite(c);
    if (!mounted) return;
    setState(() {
      final rows = vertical ? _verticalRows : _visibleIndices;
      if (vertical) { if (rows.isNotEmpty && !rows.contains(_verticalSelected)) { _verticalChannelIndex=rows[position.clamp(0,rows.length-1).toInt()]; _syncVerticalProgramme(reset:true); } } else if (rows.isNotEmpty && !rows.contains(_highlightIndex)) {
        _highlightIndex = rows[position.clamp(0, rows.length - 1).toInt()];
        _stepProgramme(0);
      }
    });
    if (vertical) { _scrollVerticalBoth(); _scheduleGuidePage(); } else { _scrollPreview(); }
  }

  Future<void> _moveChannel(_Channel c) async {
    final vertical = _verticalGuide;
    final rows = vertical ? _verticalRows : _visibleIndices;
    if ((vertical ? _verticalGroupKey=='Últimos canales' : _recentOnly) || rows.length < 2) return;
    final original = rows.indexOf(widget.channels.indexOf(c));
    if (original < 0) return;
    final position = await showDialog<int>(context: context, builder: (_) => _ChannelOrderDialog(
      names: [for (final i in rows) _name(widget.channels[i])], original: original));
    if (position == null || position == original || !mounted) return;
    final playing = _channel;
    final group = _groups[_groupIndex];
    final ordered = [for (final i in rows) widget.channels[i]];
    ordered.insert(position, ordered.removeAt(original));
    if (vertical ? _verticalGroupKey=='Favoritos' : (_selectedGroup == 'Favoritos' && !_recentOnly)) {
      await widget.onFavoriteOrder(ordered.map((c) => c.favoriteId).toList());
      if (mounted) { setState(() {}); if (vertical) _scrollVerticalBoth(); else _scrollPreview(); }
      return;
    }
    setState(() {
      for (var i = 0; i < rows.length; i++) { widget.channels[rows[i]] = ordered[i]; }
      _rebuildChannelIndices();
      _channelIndex = widget.channels.indexOf(playing);
      _highlightIndex = widget.channels.indexOf(c);
      if (vertical) _verticalChannelIndex = _highlightIndex;
      _groupIndex = _groups.indexOf(group).clamp(0, _groups.length - 1).toInt();
      final currentIds = widget.channels.map((c) => c.favoriteId).toList();
      final currentSet = currentIds.toSet();
      widget.custom['order'] = [...currentIds, ...(widget.custom['order'] as List? ?? []).whereType<String>().where((id) => !currentSet.contains(id))];
    });
    await _saveCustom();
    if (vertical) { _scrollVerticalBoth(); _scheduleGuidePage(); } else { _scrollPreview(); }
  }

  bool get _programmeHasFocus => _verticalGuide ? _verticalColumn==1 && _verticalProgramme!=null : _preview && !_groupFocus && _inProgrammes && _selectedProgramme!=null;
  Future<void> _programmeContext() async {
    if (!_programmeHasFocus) return;
    final vertical = _verticalGuide;
    final c = widget.channels[vertical?_verticalSelected:_highlightIndex];
    final p = vertical?_verticalProgramme:_selectedProgramme;
    if (p==null) return;
    final entries = List<_Programme>.of(_guide[widget.epgId(c)] ?? const <_Programme>[]);
    final initial=entries.indexWhere((e)=>e.start==p.start&&e.stop==p.stop);
    if(initial<0)return;
    final action=await _consultationDialog<String>(barrierColor:Colors.black26,builder:(ctx)=>AlertDialog(
      backgroundColor:const Color(0xFF1B202A),title:Text(p.title,maxLines:2,overflow:TextOverflow.ellipsis),
      content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Text('${_name(c)} · ${_clock(p.start)} – ${_clock(p.stop)}',style:const TextStyle(color:Colors.white70,fontSize:13)),
        const SizedBox(height:12),TextButton.icon(autofocus:true,style:_iptvDialogButtonStyle,icon:const Icon(Icons.info_outline),label:const Text('Información'),onPressed:()=>Navigator.pop(ctx,'info')),
      ]),
    ));
    if(!mounted||action!='info')return;
    await Future<void>.delayed(const Duration(milliseconds:200));
    if(!mounted)return;
    var last=initial;
    await _consultationDialog<void>(barrierColor:Colors.black54,builder:(_)=>_ProgrammeInfoDialog(entries:entries,initial:initial,channelName:_name(c),channelLogo:_logo(c),channelNumber:vertical&&_verticalGroupKey=='Favoritos'?_verticalRows.indexOf(_verticalSelected)+1:vertical?_verticalSelected+1:_channelNumber(_highlightIndex),onSelected:(i)=>last=i));
    if(!mounted)return;
    final target=entries[last];
    final index=_channelIndices[c.favoriteId];
    if(index==null)return;
    setState((){
      if(vertical){
        _verticalChannelIndex=index;_verticalColumn=1;_verticalProgrammeStart=target.start;_syncVerticalProgramme();
      }else{
        _highlightIndex=index;_groupFocus=false;_inProgrammes=true;
        final now=DateTime.now(),base=DateTime(now.year,now.month,now.day,now.hour,now.minute<30?0:30);
        _timeShift=(target.start.difference(base).inSeconds/1800).floor();
        _guideAnchor=target.start;
        _programmeIndex=_programmes(index).indexWhere((e)=>e.start==target.start&&e.stop==target.stop);
      }
    });
    if(vertical)_scrollVerticalBoth();else _scrollPreview();
    _scheduleGuidePage();
  }

  Future<void> _channelContext() async {
    final vertical = _verticalGuide;
    if (vertical ? _verticalRows.isEmpty : _visibleIndices.isEmpty) return;
    final c = widget.channels[vertical ? _verticalSelected : _highlightIndex];
    final action = await _consultationDialog<String>(barrierColor: Colors.black26, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1B202A), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), title: Text(_name(c), style: const TextStyle(color: Colors.white, fontSize: 18)),
      content: SizedBox(width: 300, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextButton.icon(autofocus: true, style: _iptvDialogButtonStyle, icon: const Icon(Icons.edit, size: 19), label: const Text('Renombrar canal'), onPressed: () => Navigator.pop(ctx, 'rename')),
        if (!(vertical ? _verticalGroupKey=='Últimos canales' : _recentOnly)) TextButton.icon(style: _iptvDialogButtonStyle, icon: const Icon(Icons.swap_vert, size: 19), label: const Text('Mover canal'), onPressed: () => Navigator.pop(ctx, 'move')),
        TextButton.icon(style: _iptvDialogButtonStyle, icon: const Icon(Icons.image, size: 19), label: const Text('Origen del logotipo'), onPressed: () => Navigator.pop(ctx, 'logo')),
        TextButton.icon(style: _iptvDialogButtonStyle, icon: const Icon(Icons.calendar_today, size: 19), label: const Text('Asignar EPG'), onPressed: () => Navigator.pop(ctx, 'epg')),
        TextButton.icon(style: _iptvDialogButtonStyle, icon: const Icon(Icons.star_border, size: 19), label: Text(widget.isFavorite(c) ? 'Quitar de favoritos' : 'Añadir a favoritos'), onPressed: () => Navigator.pop(ctx, 'favorite')),
        TextButton.icon(style: _iptvDialogButtonStyle, icon: const Icon(Icons.info_outline, size: 19), label: const Text('Información técnica'), onPressed: () => Navigator.pop(ctx, 'technical')),
      ])),
    ));
    if (!mounted) return;
    if (action == 'favorite') await _toggleGuideFavorite(c);
    if (action == 'rename' || action == 'move' || action == 'logo') {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      if (action == 'rename') await _renameChannel(c);
      if (action == 'move') await _moveChannel(c);
      if (action == 'logo') await _chooseLogo(c);
    }
    if (action == 'epg') { await Future<void>.delayed(const Duration(milliseconds: 200)); if (mounted) await _assignEpg(c); }
    if (action == 'technical' && mounted) { await _readStats(); if (mounted) { setState(() { _technicalVisible = true; _showName = true; }); _hideLater(); } }
    if (mounted) { _playerFocus.requestFocus(); _scheduleResize(); }
  }

  Future<void> _assignEpg(_Channel c) async {
    final names = widget.epgNames(c);
    final ids = names.keys.toList();
    final selected = await showDialog<String>(context: context, barrierColor: Colors.black26,
      builder: (_) => _EpgChannelPicker(title: _name(c), ids: ids, names: names, selectedId: widget.rawEpgId(c)));
    if (!mounted || selected == null) return;
    await widget.onAssignEpg(c, selected.isEmpty ? null : selected);
    if (mounted) setState(() { final at = _guideAnchor ?? DateTime.now(); _programmeIndex = _programmes(_highlightIndex).indexWhere((p) => !at.isBefore(p.start) && at.isBefore(p.stop)); });
  }

  Future<void> _options() async {
    final selected = _preview || _showChannels ? widget.channels[_highlightIndex] : _channel;
    final action = await _consultationDialog<String>(builder: (ctx) => AlertDialog(
      title: Text(_name(selected)), actions: [
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
    FocusManager.instance.addEarlyKeyEventHandler(_iptvEarlyKey);
    _consultationIdle = Timer.periodic(const Duration(seconds: 1), (_) => _checkConsultationIdle());
    unawaited(visionDiscoverIptvEnabled().then((enabled) { if (mounted) setState(() => _discoverRow = enabled); }));
    _rebuildChannelIndices();
    if (_preparingCatalog) _catalogFallback = Timer(const Duration(seconds: 4), _beginCatalog);
    _channelIndex = widget.channels.indexOf(widget.channel);
    if (_channelIndex < 0) _channelIndex = 0;
    _highlightIndex = _channelIndex;
    _preview = !widget.startFullscreen;
    _tuned = widget.startFullscreen;
    _switching = _tuned;
    widget.guideSource.addListener(_guideChanged);
    _autoRefreshTimer = Timer.periodic(const Duration(seconds:15), (_) { unawaited(_runAutomaticRefresh()); });
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) { if (mounted && (_preview || _verticalGuide || _showName)) setState(() {}); });
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
        if (mounted) { setState(() => _failed = true); _beginCatalog(); }
      });
      _frames = player.streams.playbackRestart.listen((_) {
        if (mounted) {
          if (!_ready) {
            debugPrint('[VisionIPTV] playback restart: ${_startup.elapsedMilliseconds} ms');
          }
          final firstFrame = !_ready;
          setState(() { _ready = true; _failed = false; });
          if (firstFrame) { _autoFirstReady ??= DateTime.now(); _lastInteraction = DateTime.now(); _beginCatalog(); unawaited(widget.onTuned(_channel)); if (widget.afr) unawaited(_matchIptvRate(player, _afrGeneration)); }
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
      try { await player.setAudioPassthrough(widget.passthrough); } catch (_) {}
      await _openChannel(player);
    } catch (error) {
      _beginCatalog();
      debugPrint('[VisionDRM] playback preparation failed: ${error.runtimeType}');
      unawaited(_wakelock.setEnabled(false));
      if (mounted) setState(() => _failed = true);
    } finally {
      _switching = false;
    }
  }

  Future<void> _openChannel(Player player) async {
      _afrGeneration++;
      debugPrint('[VisionIPTV] opening: ${_startup.elapsedMilliseconds} ms');
      await openVisionIptvMedia(player, _channel, widget.useExoPlayer, widget.forceHls);
      debugPrint('[VisionIPTV] open returned: ${_startup.elapsedMilliseconds} ms');
      if (mounted) { _scheduleResize(); if (!_preview && _ready) unawaited(widget.onFullscreen(_channel)); _hideLater(); }
  }

  Future<void> _matchIptvRate(Player player, int generation) async {
    if (!Platform.isAndroid) return;
    try {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted || _closing != null || player != _player || generation != _afrGeneration) return;
        final format = await PlayerOutputFormat.read(player);
        final fps = format.fps;
        if (!mounted || _closing != null || player != _player || generation != _afrGeneration) return;
        if (fps == null || !fps.isFinite || fps < 10 || fps > 120) continue;
        _afrSwitching = true;
        try { await player.setVideoFrameRate(fps, 0); }
        finally { _afrSwitching = false; }
        return;
      }
    } catch (_) { _afrSwitching = false; }
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
      _bannerProgramme = null;
      if (_highlightIndex != next) {
        _highlightIndex = next;
        _guideAnchor = null; _timeShift = 0;
        _stepProgramme(0);
      }
      _showChannels = false;
      _ready = false;
      _failed = false;
      _pendingTuneBanner = _preview || _verticalGuide;
      _showName = !_pendingTuneBanner;
      _technical = '';
      _technicalVisible = false;
    });
    _scheduleGuidePage();
    _afrGeneration++;
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

  List<int> get _popupIndices => _visibleIndices;

  void _scrollToHighlight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showChannels || !_channelScroll.hasClients) return;
      final position = _channelScroll.position;
      final target = (_popupIndices.indexOf(_highlightIndex) * 56.0 - position.viewportDimension / 2 + 28)
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
      if (mounted) setState(() { _showName = false; _bannerProgramme = null; });
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
      if (widget.afr) { try { await player.clearVideoFrameRate(); } catch (_) {} }
      try { await player.dispose(); } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && (_afrSwitching || _externalPicker)) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(_close());
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_iptvEarlyKey);
    _consultationIdle?.cancel();
    widget.guideSource.removeListener(_guideChanged);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _channelScroll.dispose();
    _leftHold?.cancel(); _backHold?.cancel(); _favoriteHold?.cancel(); _statusTimer?.cancel();
    _clockTimer?.cancel(); _guidePageTimer?.cancel(); _catalogFallback?.cancel(); _autoRefreshTimer?.cancel();
    _verticalChannelsScroll.dispose(); _verticalProgrammesScroll.dispose(); _verticalSynopsisScroll.dispose(); _verticalGroupsScroll.dispose();
    _groupScroll.dispose();
    _settingsScroll.dispose();
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

  Rect _verticalVideoRect(Size size) {
    final usable = (size.width - 40).clamp(1.0, 10000.0).toDouble();
    final width = (usable * .41 - 8).clamp(1.0, 10000.0).toDouble();
    final height = (width * 9 / 16).clamp(1.0, (size.height * .48).clamp(1.0,10000.0).toDouble()).toDouble();
    return Rect.fromLTWH(size.width - 20 - width, 44, width, height);
  }
  List<int> get _verticalRows {
    final key = _verticalGroupKey ?? _groupKey(_channel.source,_channel.group);
    final rows = key == 'Favoritos' || key == 'Últimos canales' ? [for (final id in (key=='Favoritos'?widget.favoriteOrder():widget.recent())) if (_channelIndices.containsKey(id) && (key=='Favoritos'||!widget.isHidden(widget.channels[_channelIndices[id]!])||widget.isFavorite(widget.channels[_channelIndices[id]!]))) _channelIndices[id]!] : (_groupRows[key] ?? const <int>[]);
    return rows;
  }
  int get _verticalSelected => (_verticalChannelIndex ?? _channelIndex).clamp(0,widget.channels.length-1).toInt();
  List<_Programme> get _verticalProgrammes => _verticalRows.isEmpty ? const <_Programme>[] : (_guide[widget.epgId(widget.channels[_verticalSelected])] ?? const <_Programme>[]);
  _Programme? get _verticalProgramme {
    final entries = _verticalProgrammes;
    return _verticalProgrammeIndex >= 0 && _verticalProgrammeIndex < entries.length ? entries[_verticalProgrammeIndex] : null;
  }
  void _syncVerticalProgramme({bool reset = false}) {
    final entries = _verticalProgrammes;
    final now = DateTime.now();
    final anchor = reset ? null : _verticalProgrammeStart;
    var index = anchor == null ? -1 : entries.indexWhere((p) => p.start == anchor);
    if (index < 0) index = entries.indexWhere((p) => !now.isBefore(p.start) && now.isBefore(p.stop));
    if (index < 0) index = entries.indexWhere((p) => p.start.isAfter(now));
    if (index < 0 && entries.isNotEmpty) index = entries.length - 1;
    _verticalProgrammeIndex = index;
    _verticalProgrammeStart = index < 0 ? null : entries[index].start;
  }
  bool _verticalDayStarts(List<_Programme> entries,int i) { if (i == 0) return true; final a = entries[i-1].start.toLocal(), b = entries[i].start.toLocal(); return a.year != b.year || a.month != b.month || a.day != b.day; }
  List<int?> _verticalScheduleRows(List<_Programme> entries) => [for (var i=0;i<entries.length;i++) ...[if (_verticalDayStarts(entries,i)) null, i]];
  void _scrollVertical(ScrollController controller,int index,double extent) {
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_verticalGuide || !controller.hasClients) return;
      final p = controller.position;
      final row = identical(controller,_verticalProgrammesScroll) ? _verticalScheduleRows(_verticalProgrammes).indexOf(index) : index;
      if (row < 0) return;
      final actualExtent = identical(controller,_verticalProgrammesScroll) ? _verticalProgrammeExtent : _verticalChannelExtent;
      controller.jumpTo((row * actualExtent - p.viewportDimension / 2 + actualExtent / 2).clamp(0.0,p.maxScrollExtent).toDouble());
    });
  }
  void _scrollVerticalBoth() {
    _scrollVertical(_verticalChannelsScroll,_verticalRows.indexOf(_verticalSelected),_verticalChannelExtent);
    _scrollVertical(_verticalProgrammesScroll,_verticalProgrammeIndex,_verticalProgrammeExtent);
  }
  void _openVerticalGuide() {
    if (_verticalGuide || _preview || _zooming) return;
    _timer?.cancel();
    _pendingChannelWrap = null; _fastScroll = false;
    setState(() {
      _verticalGuide = true; _showName = false; _showChannels = false;
      _verticalColumn = 1; _verticalChannelIndex = _channelIndex;
      _verticalGroupKey = _selectedGroup == 'Favoritos' && widget.isFavorite(_channel) ? 'Favoritos' : _groupKey(_channel.source,_channel.group);
      _verticalProgrammeStart = null; _syncVerticalProgramme(reset:true);
    });
    if (_preparingCatalog) _beginCatalog();
    _scheduleResize(); _scheduleGuidePage(); _scrollVerticalBoth();
  }
  void _closeVerticalGuide() {
    if (!_verticalGuide) return;
    _pendingChannelWrap = null; _fastScroll = false;
    final showTune = _pendingTuneBanner; _pendingTuneBanner = false;
    setState(() { _verticalGuide = false; _showName = showTune; _bannerProgramme = null; _verticalChannelIndex = null; _verticalGroupKey = null; });
    if (showTune) _hideLater();
    _scheduleResize(); _scheduleGuidePage(); _playerFocus.requestFocus();
  }
  void _moveVertical(int delta, {bool wrap = true}) {
    if (_preparingCatalog) return;
    if (_verticalColumn == -2) { setState(()=>_menuIndex=(_menuIndex+delta).clamp(0,_menuLabels.length-1).toInt()); return; }
    if (_verticalColumn == -1) { _moveVerticalGroup(delta); return; }
    if (_verticalColumn == 2) {
      if (_verticalSynopsisScroll.hasClients) { final p = _verticalSynopsisScroll.position; _verticalSynopsisScroll.jumpTo((p.pixels + delta * 42).clamp(0.0,p.maxScrollExtent).toDouble()); }
      return;
    }
    if (_verticalSynopsisScroll.hasClients) _verticalSynopsisScroll.jumpTo(0);
    if (_verticalColumn == 0) {
      final rows = _verticalRows;
      if (rows.isEmpty) return;
      final pos = rows.indexOf(_verticalSelected);
      if (!wrap && pos >= 0 && (pos + delta < 0 || pos + delta >= rows.length)) return;
      final next = rows[(pos + delta + rows.length) % rows.length];
      setState(() { _verticalChannelIndex = next; _verticalProgrammeStart = null; _syncVerticalProgramme(reset:true); });
      _scheduleGuidePage(); _scrollVerticalBoth();
    } else {
      final entries = _verticalProgrammes;
      if (entries.isEmpty) return;
      setState(() {
        _verticalProgrammeIndex = (_verticalProgrammeIndex + delta).clamp(0,entries.length-1).toInt();
        _verticalProgrammeStart = entries[_verticalProgrammeIndex].start;
      });
      _scrollVertical(_verticalProgrammesScroll,_verticalProgrammeIndex,_verticalProgrammeExtent);
    }
  }
  Future<void> _confirmVertical() async {
    if (_preparingCatalog || _switching) return;
    if (_verticalColumn == -2) { await _activateVerticalMenu(); return; }
    if (_verticalColumn == -1) { _chooseVerticalGroup(); return; }
    if (_verticalColumn == 0 || _verticalColumn == 1) {
      if (_verticalRows.isEmpty) return;
      if (_verticalColumn==1) { final p=_verticalProgramme; if(p==null)return; if(!_isOnAir(p)){await _withDialog(_programmeContext);return;} }
      final target = _verticalSelected;
      if (target == _channelIndex && !_failed) { _closeVerticalGuide(); return; }
      await _switchChannel(target);
      if (!mounted || !_verticalGuide) return;
      setState(() { _showName = false; _verticalChannelIndex = _channelIndex; _syncVerticalProgramme(reset:true); });
      _scheduleGuidePage(); _scrollVerticalBoth();
    }
  }
  Future<void> _activateVerticalMenu() async {
    switch (_menuIndex) {
      case 0:
      case 1:
      case 2:
        setState(() { _verticalGroupFocus = _menuIndex==0?'Todos':_menuIndex==1?'Favoritos':'Últimos canales'; });
        _chooseVerticalGroup(enterChannels:true);
        break;
      case 3:
        widget.queueManualGuide();
        setState(()=>_menuStatus='Actualización EPG en segundo plano solicitada');
        break;
      case 4:
        await _openSettings();
        break;
      case 5:
        await _exitIptv();
        break;
    }
  }
  Future<void> _previousChannel() async {
    if (_switching || _preparingCatalog) return;
    for (final id in widget.recent()) {
      final index = _channelIndices[id];
      if (id == _channel.favoriteId || index == null || index == _channelIndex) continue;
      final c = widget.channels[index];
      if (widget.isHidden(c) && !widget.isFavorite(c)) continue;
      await _switchChannel(index);
      return;
    }
  }
  Widget _verticalGuidePanel(Rect video) {
    final rows = _verticalRows;
    final programmes = _verticalProgrammes;
    final programmeRows = _verticalScheduleRows(programmes);
    final selected = _verticalProgramme;
    final now = DateTime.now();
    final focusedChannel = widget.channels[_verticalSelected];
    const blue = Color(0xFF90CAF9), surface = Color(0xFF242A36), header = Color(0xFF303847);
    const muted = Colors.white70;
    final key = _verticalGroupKey ?? _groupKey(_channel.source,_channel.group);
    final parts = _groupParts(key);
    final groupLabel = key == 'Favoritos' ? 'Todas las listas • Favoritos' : key == 'Todos' ? 'Todas las listas • Todos los canales' : parts == null ? _groupLabel(key) : '${_sourceLabels[parts[0]] ?? 'Lista IPTV'} • ${parts[1] == null || parts[1] == '' ? 'Todos' : parts[1]}';
    final date = now.toLocal();
    const days = ['lun.','mar.','mié.','jue.','vie.','sáb.','dom.'];
    const months = ['ene.','feb.','mar.','abr.','may.','jun.','jul.','ago.','sep.','oct.','nov.','dic.'];
    String dayLabel(DateTime d) {
      final local = d.toLocal();
      final today = DateTime(date.year,date.month,date.day);
      final day = DateTime(local.year,local.month,local.day);
      if (day == today) return 'Hoy';
      if (day == DateTime(date.year,date.month,date.day+1)) return 'Mañana';
      if (day == DateTime(date.year,date.month,date.day-1)) return 'Ayer';
      return '${days[local.weekday-1]} ${local.day} ${months[local.month-1]}';
    }
    _Programme? currentFor(_Channel c) {
      for (final p in _guide[widget.epgId(c)] ?? const <_Programme>[]) {
        if (!now.isBefore(p.start) && now.isBefore(p.stop)) return p;
      }
      return null;
    }
    double progress(_Programme p) => (now.difference(p.start).inSeconds / p.stop.difference(p.start).inSeconds.clamp(1,9999999)).clamp(0.0,1.0).toDouble();
    Widget logoFor(_Channel c,double width,double height,Color fg) {
      final logo = _logo(c);
      return SizedBox(width:width,height:height,child:logo.isEmpty?Icon(Icons.tv,color:fg,size:height*.6):Image.network(logo,cacheWidth:128,fit:BoxFit.contain,errorBuilder:(_,__,___)=>Icon(Icons.tv,color:fg,size:height*.6)));
    }
    Widget panel(Widget child) => DecoratedBox(decoration:BoxDecoration(color:surface,borderRadius:BorderRadius.circular(9)),child:ClipRRect(borderRadius:BorderRadius.circular(9),child:child));
    return Padding(padding:const EdgeInsets.fromLTRB(20,8,20,10),child:Column(children:[
      SizedBox(height:28,child:Row(children:[
        const Expanded(child:Text('Plezy Vision  |  IPTV · Guía de programación',maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:muted,fontSize:15,fontWeight:FontWeight.w600))),
        Text('${days[date.weekday-1]}, ${date.day} ${months[date.month-1]} ${_clock(now)}',style:const TextStyle(color:blue,fontSize:15,fontWeight:FontWeight.bold)),
      ])),
      const SizedBox(height:8),
      Expanded(child:LayoutBuilder(builder:(_,constraints) {
        final rightWidth = video.width;
        final leftWidth = (constraints.maxWidth * .28).clamp(1.0,10000.0).toDouble();
        final headerHeight = (constraints.maxHeight * .10).clamp(35.0,52.0).toDouble();
        _verticalChannelExtent = ((constraints.maxHeight-headerHeight-8)/8).clamp(1.0,10000.0).toDouble();
        _verticalProgrammeExtent = ((constraints.maxHeight-headerHeight-8)/13).clamp(24.0,55.0).toDouble();
        final movableWidth = constraints.maxWidth-rightWidth-12;
        final programmeWidth = (movableWidth-leftWidth-10).clamp(1.0,10000.0).toDouble();
        final groupWidth = programmeWidth;
        final menuWidth = leftWidth;
        final groupKeys = _verticalGroups;
        _verticalGroupExtent = ((constraints.maxHeight-headerHeight-8)/12).clamp(30.0,55.0).toDouble();
        final groupPanel = SizedBox(width:groupWidth,child:panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Container(height:headerHeight,color:header,padding:const EdgeInsets.symmetric(horizontal:10),alignment:Alignment.centerLeft,child:const Text('Grupos',style:TextStyle(color:Colors.white,fontSize:16,fontWeight:FontWeight.bold))),
          const SizedBox(height:4),Expanded(child:ListView.builder(padding:const EdgeInsets.symmetric(horizontal:5),controller:_verticalGroupsScroll,itemExtent:_verticalGroupExtent,itemCount:groupKeys.length,cacheExtent:_verticalGroupExtent*2,addAutomaticKeepAlives:false,itemBuilder:(_,i){
            final g=groupKeys[i], p=_groupParts(g); final isHeader=p!=null&&p[1]==null; final focused=_verticalColumn==-1&&g==_verticalGroupFocus; final fg=focused?const Color(0xFF10151D):Colors.white;
            return Container(margin:const EdgeInsets.only(bottom:2),padding:EdgeInsets.only(left:p!=null&&!isHeader?20:8,right:8),decoration:BoxDecoration(color:focused?const Color(0xFFE3EEFF):g==key?const Color(0xFF39485B):Colors.transparent,borderRadius:BorderRadius.circular(6)),child:Row(children:[
              if(isHeader) Icon(_expandedSources.contains(p![0])?Icons.expand_more:Icons.chevron_right,color:fg,size:17) else if(g=='Favoritos') Icon(Icons.star_border,color:fg,size:16) else if(g=='Todos') Icon(Icons.list,color:fg,size:16),
              const SizedBox(width:6),Expanded(child:Text(_groupLabel(g),maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:fg,fontSize:14,fontWeight:isHeader?FontWeight.bold:FontWeight.normal))),
            ]));
          })),const SizedBox(height:4),
        ])));
        final menuPanel = SizedBox(width:menuWidth,child:panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Container(height:headerHeight,color:header,padding:const EdgeInsets.symmetric(horizontal:10),alignment:Alignment.centerLeft,child:const Text('IPTV',style:TextStyle(color:Colors.white,fontSize:16,fontWeight:FontWeight.bold))),
          const SizedBox(height:4),
          Expanded(child:ListView.builder(padding:const EdgeInsets.symmetric(horizontal:5),itemExtent:_verticalGroupExtent,itemCount:_menuLabels.length,itemBuilder:(_,i){
            final focused=_verticalColumn==-2&&i==_menuIndex,fg=focused?const Color(0xFF10151D):Colors.white;
            return Container(margin:const EdgeInsets.only(bottom:2),padding:const EdgeInsets.symmetric(horizontal:8),decoration:BoxDecoration(color:focused?const Color(0xFFE3EEFF):Colors.transparent,borderRadius:BorderRadius.circular(6)),child:Row(children:[Icon(_menuIcons[i],color:fg,size:18),const SizedBox(width:8),Expanded(child:Text(_menuLabels[i],maxLines:2,overflow:TextOverflow.ellipsis,style:TextStyle(color:fg,fontSize:14)))]));
          })),
          if(_menuStatus.isNotEmpty) Padding(padding:const EdgeInsets.all(8),child:Text(_menuStatus,style:const TextStyle(color:muted,fontSize:11))),
        ])));
        return Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
          SizedBox(width:movableWidth,height:constraints.maxHeight,child:ClipRect(child:Stack(children:[
            AnimatedPositioned(duration:const Duration(milliseconds:180),curve:Curves.easeOutCubic,left:_verticalColumn==-2?0:_verticalColumn==-1?-(menuWidth+10):-(menuWidth+10+groupWidth+10),top:0,bottom:0,width:menuWidth+10+groupWidth+10+movableWidth,child:Row(children:[
          menuPanel,const SizedBox(width:10),groupPanel,const SizedBox(width:10),
          SizedBox(width:leftWidth,child:panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Container(height:headerHeight,color:header,padding:const EdgeInsets.symmetric(horizontal:10),alignment:Alignment.centerLeft,child:Text(groupLabel,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white,fontSize:15,fontWeight:FontWeight.bold))),
            const SizedBox(height:4),
            Expanded(child:_preparingCatalog ? const Center(child:Text('Preparando guía…',style:TextStyle(color:muted))) :
              rows.isEmpty ? const Center(child:Text('Sin canales',style:TextStyle(color:muted))) : ListView.builder(padding:const EdgeInsets.symmetric(horizontal:5),controller:_verticalChannelsScroll,itemExtent:_verticalChannelExtent,itemCount:rows.length,cacheExtent:_verticalChannelExtent*2,addAutomaticKeepAlives:false,itemBuilder:(_,i) {
                final index = rows[i], c = widget.channels[index];
                final chosen = index == _verticalSelected, focused = chosen && _verticalColumn == 0;
                final fg = focused ? const Color(0xFF10151D) : Colors.white;
                final live = currentFor(c);
                final h = _verticalChannelExtent;
                return Container(margin:const EdgeInsets.only(bottom:2),padding:const EdgeInsets.symmetric(horizontal:7),
                  decoration:BoxDecoration(color:focused?const Color(0xFFE3EEFF):chosen?const Color(0xFF39485B):Colors.transparent,borderRadius:BorderRadius.circular(7)),
                  child:Row(children:[
                    logoFor(c,(h*.82).clamp(24.0,54.0).toDouble(),(h*.64).clamp(20.0,42.0).toDouble(),fg),
                    const SizedBox(width:7),Expanded(child:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[
                      Text('${key == 'Favoritos' ? i+1 : index+1}  ${_name(c)}',maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:fg,fontSize:14,fontWeight:FontWeight.w600)),
                      if (live != null) ...[
                        Text(live.title,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:focused?const Color(0xFF34485E):blue,fontSize:12)),
                        const SizedBox(height:3),
                        LinearProgressIndicator(value:progress(live),minHeight:2,color:focused?const Color(0xFF307BD6):blue,backgroundColor:focused?Colors.black26:Colors.white24),
                      ],
                    ])),
                    if (widget.isFavorite(c)) const Padding(padding:EdgeInsets.only(left:3),child:Icon(Icons.star,color:Colors.amber,size:12)),
                    if (index == _channelIndex) Icon(Icons.play_arrow,color:fg,size:15),
                  ]));
              })),
            const SizedBox(height:4),
          ]))),
          const SizedBox(width:10),
          SizedBox(width:programmeWidth,child:panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Container(height:headerHeight,color:header,padding:const EdgeInsets.symmetric(horizontal:9),child:Row(children:[
              logoFor(focusedChannel,headerHeight*.85,headerHeight*.75,Colors.white),
              const SizedBox(width:8),Expanded(child:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(_name(focusedChannel),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white,fontSize:16,fontWeight:FontWeight.bold)),
                Text([focusedChannel.sourceName,focusedChannel.group].where((v)=>v.isNotEmpty).join(' • '),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:muted,fontSize:12)),
              ])),
            ])),
            const SizedBox(height:4),
            Expanded(child:programmes.isEmpty?const Center(child:Text('Sin programación',style:TextStyle(color:muted))):
              ListView.builder(padding:const EdgeInsets.symmetric(horizontal:5),controller:_verticalProgrammesScroll,itemExtent:_verticalProgrammeExtent,itemCount:programmeRows.length,cacheExtent:_verticalProgrammeExtent*2,addAutomaticKeepAlives:false,itemBuilder:(_,row) {
                final i = programmeRows[row];
                if (i == null) { final next = programmeRows[row+1]!; return Padding(padding:const EdgeInsets.symmetric(horizontal:7),child:Align(alignment:Alignment.centerLeft,child:Text(dayLabel(programmes[next].start),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:blue,fontSize:14,fontWeight:FontWeight.bold)))); }
                final p = programmes[i], chosen = i == _verticalProgrammeIndex, focused = chosen && _verticalColumn == 1;
                final live = !now.isBefore(p.start) && now.isBefore(p.stop);
                final fg = focused?const Color(0xFF10151D):live?blue:Colors.white;
                return Container(margin:const EdgeInsets.only(bottom:2),padding:const EdgeInsets.symmetric(horizontal:7),
                  decoration:BoxDecoration(color:focused?const Color(0xFFE3EEFF):chosen?const Color(0xFF39485B):Colors.transparent,borderRadius:BorderRadius.circular(6)),
                  child:Row(children:[
                    SizedBox(width:50,child:Text(_clock(p.start),style:TextStyle(color:fg,fontSize:13))),
                    Expanded(child:Text(p.title,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:fg,fontSize:14,fontWeight:focused?FontWeight.w600:FontWeight.normal))),
                    if (live) Icon(Icons.play_arrow,color:fg,size:13),
                  ]));
              })),
            const SizedBox(height:4),
          ]))),
          ])),
          if (_settingsOpen) Positioned.fill(child:_iptvSettingsPanel()),
          ]))),
          const SizedBox(width:12),
          SizedBox(width:rightWidth,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            SizedBox(height:video.height),
            const SizedBox(height:10),
            Expanded(child:DecoratedBox(decoration:BoxDecoration(color:surface,borderRadius:BorderRadius.circular(9),border:Border.all(color:_verticalColumn==2?blue:Colors.transparent,width:2)),child:Padding(padding:const EdgeInsets.all(10),child:selected==null?const Center(child:Text('Sin programación',style:TextStyle(color:muted))):Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(selected.title,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white,fontSize:17,fontWeight:FontWeight.bold)),
              const SizedBox(height:5),
              Row(children:[
                Text('${_clock(selected.start)} – ${_clock(selected.stop)}',style:const TextStyle(color:muted,fontSize:12)),
                if (!now.isBefore(selected.start)&&now.isBefore(selected.stop)) ...[
                  const SizedBox(width:7),Expanded(child:LinearProgressIndicator(value:progress(selected),minHeight:3,color:blue,backgroundColor:Colors.white24)),
                  const SizedBox(width:7),Text('${selected.stop.difference(now).inMinutes} min',style:const TextStyle(color:muted,fontSize:12)),
                ],
              ]),
              const SizedBox(height:8),
              Expanded(child:LayoutBuilder(builder:(_,c) => Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
                if (selected.poster.startsWith('http') && c.maxWidth>=170 && c.maxHeight>=65 && !_fastScroll) ...[
                  SizedBox(width:(c.maxWidth*.29).clamp(40.0,112.0).toDouble(),height:c.maxHeight,child:ClipRRect(borderRadius:BorderRadius.circular(6),child:Image.network(selected.poster,cacheHeight:256,fit:BoxFit.contain,alignment:Alignment.topCenter,errorBuilder:(_,__,___)=>const SizedBox.shrink()))),
                  const SizedBox(width:9),
                ],
                Expanded(child:Scrollbar(controller:_verticalSynopsisScroll,thumbVisibility:_verticalColumn==2,child:SingleChildScrollView(controller:_verticalSynopsisScroll,padding:const EdgeInsets.only(right:8),child:Text(selected.description,style:const TextStyle(color:Colors.white,fontSize:14,height:1.22))))),
              ]))),
            ])))),
          ])),
        ]);
      })),
    ]));
  }

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
        Expanded(child: Text(p?.title ?? _name(channel), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
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
        Flexible(child: Text([channel.sourceName, channel.group].where((v) => v.isNotEmpty).join(' - '), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: const TextStyle(color: Colors.white70, fontSize: 12))),
      ]),
      const SizedBox(height: 7),
      Expanded(child: Text(p?.description ?? '', maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 14))),
    ]);
    if (poster.isEmpty || _fastScroll || !poster.startsWith('http')) return details;
    return Row(children: [Expanded(child: details), const SizedBox(width: 12), SizedBox(width: 108, height: 162, child: ClipRRect(borderRadius: BorderRadius.circular(9), child: Image.network(poster, cacheHeight: 324, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink())))]);
  }

  Widget _groupTile(int index, Color focus, Color surface) {
    final key = _groups[index], p = _groupParts(key);
    final header = p != null && p[1] == null;
    final selected = index == _groupIndex;
    final fg = selected ? Colors.black : Colors.white;
    return Container(height: 36, margin: const EdgeInsets.only(bottom: 2), padding: EdgeInsets.only(left: p != null && !header ? 20 : 9, right: 6),
      decoration: BoxDecoration(color: selected ? focus : header ? const Color(0xFF343A45) : surface, borderRadius: BorderRadius.circular(7)),
      child: Row(children: [
        if (key == 'Favoritos') Icon(Icons.star, size: 16, color: selected ? Colors.black : Colors.amber),
        if (header) Icon(_expandedSources.contains(p[0]) ? Icons.expand_more : Icons.chevron_right, size: 17, color: fg),
        if (header || key == 'Favoritos') const SizedBox(width: 5),
        Expanded(child: Text(_groupLabel(key), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 13, fontWeight: header ? FontWeight.bold : FontWeight.normal))),
      ]));
  }

  Widget _previewGuide() {
    if (_preparingCatalog) return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Preparando guía…', style: TextStyle(color: Colors.white70))]));
    if (_catalogError != null && !_menuOpen && !_settingsOpen) return Center(child: Text(_catalogError!, style: const TextStyle(color: Colors.white70)));
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
      if (_groupFocus) SizedBox(width: 170, child: Column(children: [
        _groupTile(1, focus, surface),
        _groupTile(0, focus, surface),
        Expanded(child: ListView.builder(controller: _groupScroll, itemExtent: 38, itemCount: _groups.length - 2, itemBuilder: (_, i) => _groupTile(i + 2, focus, surface))),
      ])),
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
            ListView.builder(controller: _previewScroll, itemExtent: 54, cacheExtent: 108, addAutomaticKeepAlives: false, itemCount: rows.length, itemBuilder: (_, row) {
              final i = rows[row], channel = widget.channels[i];
              final focused = !_menuOpen && !_groupFocus && i == _highlightIndex;
              final programmes = _programmes(i);
              final channelFocused = focused && !_inProgrammes;
              return Row(children: [
                Container(width: channelWidth, margin: const EdgeInsets.symmetric(vertical: 2), padding: const EdgeInsets.all(6),
                  
                  child: Row(children: [
                    SizedBox(width: 28, child: Text('${!_recentOnly && _selectedGroup == 'Favoritos' ? row + 1 : i + 1}', style: TextStyle(color: channelFocused ? const Color(0xFF2196F3) : (_tuned && i == _channelIndex ? focus : Colors.white70)))),
                    SizedBox(width: 42, height: 30, child: _logo(channel).isEmpty ? Icon(Icons.tv, color: channelFocused ? const Color(0xFF2196F3) : Colors.white) : Image.network(_logo(channel), cacheWidth: 128, fit: BoxFit.contain, errorBuilder: (_, _, _) => Icon(Icons.tv, color: channelFocused ? const Color(0xFF2196F3) : Colors.white))),
                    const SizedBox(width: 7),
                    Expanded(child: Text(_name(channel), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: channelFocused ? const Color(0xFF2196F3) : Colors.white, fontSize: 13))),
                    if (_tuned && i == _channelIndex) Icon(Icons.play_arrow, color: channelFocused ? const Color(0xFF2196F3) : focus, size: 15),
                    if (widget.isFavorite(channel)) const Icon(Icons.star, color: Colors.amber, size: 14),
                  ])),
                SizedBox(width: width, child: Stack(fit: StackFit.expand, children: [
                  if (programmes.isEmpty) Container(margin: const EdgeInsets.all(2), alignment: Alignment.centerLeft, padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: focused && _inProgrammes ? focus : surface, borderRadius: BorderRadius.circular(6)), child: Text('Sin programación', style: TextStyle(color: focused ? Colors.black : Colors.white70))),
                  for (var j = 0; j < programmes.length; j++)
                    if (x(programmes[j].stop) - x(programmes[j].start) > 3) Positioned(left: x(programmes[j].start), width: x(programmes[j].stop) - x(programmes[j].start), top: 2, bottom: 2,
                      child: Container(margin: const EdgeInsets.symmetric(horizontal: 2), padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(color: focused && _inProgrammes && _programmeIndex == j ? focus : (!now.isBefore(programmes[j].start) && now.isBefore(programmes[j].stop) ? const Color(0xFF656565) : surface),
                          border: Border.all(color: const Color(0xFF485467)), borderRadius: BorderRadius.horizontal(left: programmes[j].start.isBefore(start) ? Radius.zero : const Radius.circular(6), right: programmes[j].stop.isAfter(end) ? Radius.zero : const Radius.circular(6))),
                        child: Align(alignment: Alignment.centerLeft, child: Text(programmes[j].title, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: focused && _inProgrammes && _programmeIndex == j ? Colors.black : Colors.white, fontSize: 12))))),
                  if (focused && _inProgrammes && _programmeIndex < 0 && programmes.isNotEmpty)
                    Builder(builder: (_) {
                      final at = _guideAnchor ?? now;
                      var left = start;
                      var right = end;
                      for (final p in programmes) {
                        if (!p.stop.isAfter(at) && p.stop.isAfter(left)) left = p.stop;
                        if (p.start.isAfter(at) && p.start.isBefore(right)) right = p.start;
                      }
                      final w = x(right) - x(left);
                      if (w <= 3) return const SizedBox.shrink();
                      return Positioned(left: x(left), width: w, top: 2, bottom: 2,
                        child: Container(margin: const EdgeInsets.symmetric(horizontal: 2), padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(color: focus, borderRadius: BorderRadius.circular(6)),
                          alignment: Alignment.centerLeft, child: const Text('Sin programación', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.black, fontSize: 12))));
                    }),
                  if (!now.isBefore(start) && now.isBefore(end)) Positioned(left: x(now), top: 0, bottom: 0, child: IgnorePointer(child: Container(width: 2, color: focus.withAlpha(160)))),
                ])),
              ]);
            })),
        ]);
      });
  }

  void _stepBanner(int delta) {
    final entries = _guide[widget.epgId(_channel)] ?? const <_Programme>[];
    final current = _bannerProgramme ?? _currentProgramme;
    final index = current == null ? -1 : entries.indexOf(current);
    final target = index + delta;
    if (index >= 0 && target >= 0 && target < entries.length) setState(() => _bannerProgramme = entries[target]);
    _hideLater();
  }

  int _channelNumber(int index) {
    if (!_recentOnly && _selectedGroup == 'Favoritos') {
      final pos = _visibleIndices.indexOf(index);
      if (pos >= 0) return pos + 1;
    }
    return index + 1;
  }

  Widget _infoBanner() {
    final current = _bannerProgramme ?? _currentProgramme;
    final entries = _guide[widget.epgId(_channel)] ?? const <_Programme>[];
    final index = current == null ? -1 : entries.indexOf(current);
    final next = index >= 0 && index + 1 < entries.length ? entries[index + 1] : _bannerProgramme == null ? _nextProgramme : null;
    final now = DateTime.now();
    final progress = current == null ? 0.0 : (now.difference(current.start).inSeconds / current.stop.difference(current.start).inSeconds.clamp(1, 9999999)).clamp(0.0, 1.0).toDouble();
    final number = _channelNumber(_channelIndex);
    final poster = current?.poster ?? '';
    final logo = _logo(_channel);
    final remaining = current == null ? 0 : current.stop.difference(now).inMinutes.clamp(0, 999999);
    final live = current != null && !now.isBefore(current.start) && now.isBefore(current.stop);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xED10151D), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (current != null) ...[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (poster.startsWith('http')) ...[
              ClipRRect(borderRadius: BorderRadius.circular(7), child: Image.network(poster, width: 96, height: 144, cacheHeight: 288, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink())),
              const SizedBox(width: 16),
            ],
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:Text(current.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold))),const SizedBox(width:12),Text(_clock(now),style:const TextStyle(color:Colors.white,fontSize:19,fontWeight:FontWeight.bold))]),
              const SizedBox(height: 5),
              if (live) Text('En emisión · Quedan $remaining min', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 14)),
              if (current.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(current.description, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14)),
              ],
              if (next != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('A continuación · ${_clock(next.start)} · ${next.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 13))),
            ])),
          ]),
        ] else ...[
          const SizedBox(height: 6),
          Row(children:[const Expanded(child:Text('Sin programación',style:TextStyle(color:Colors.white70,fontSize:14))),Text(_clock(now),style:const TextStyle(color:Colors.white,fontSize:19,fontWeight:FontWeight.bold))]),
          if (next != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('A continuación · ${_clock(next.start)} · ${next.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70))),
        ],
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: 96, height: 64, child: logo.isEmpty ? const Icon(Icons.tv, color: Colors.white, size: 36) : Image.network(logo, cacheWidth: 240, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.tv, color: Colors.white, size: 36))),
          const SizedBox(width: 16),
          Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              SizedBox(width:58,child:Text(current==null?'':_clock(current.start),style:const TextStyle(color:Colors.white70,fontSize:14))),
              Expanded(child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[
                Flexible(child:Text('$number · ${_name(_channel)}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white,fontSize:21,fontWeight:FontWeight.bold))),
                if (widget.isFavorite(_channel)) ...[const SizedBox(width:8),const Icon(Icons.star,color:Colors.amber,size:22)],
              ])),
              SizedBox(width:58,child:Text(current==null?'':_clock(current.stop),textAlign:TextAlign.right,style:const TextStyle(color:Colors.white70,fontSize:14))),
            ]),
            if (current != null) ...[
              const SizedBox(height: 8),
              ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: progress, minHeight: 6, color: const Color(0xFF90CAF9), backgroundColor: Colors.white24)),
            ],
          ])),
        ]),
        if (_technicalVisible && _technical.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_technical, style: const TextStyle(color: Colors.white70, fontSize: 12))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final verticalVideo = _verticalVideoRect(MediaQuery.sizeOf(context));
    return PopScope(
    canPop: _exiting,
    onPopInvokedWithResult: (didPop, _) { if (!didPop && !_exiting && !_dialogBusy && _backHold == null) _backShort(); },
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(focusNode: _playerFocus, autofocus: true, onKeyEvent: (_, event) {
        final key = event.logicalKey;
        _lastInteraction = DateTime.now();
        if (_zooming || _applyingLists) return KeyEventResult.handled;
        if (_dialogBusy) return KeyEventResult.ignored;
        if (event is KeyUpEvent && (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) && _backHold == null) return KeyEventResult.handled;
        if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) {
          if (event is KeyDownEvent) { _backLong = false; _backHold?.cancel(); _backHold = Timer(const Duration(milliseconds: 650), () { _backLong = true; unawaited(_exitIptv()); }); }
          if (event is KeyUpEvent) { _backHold?.cancel(); _backHold = null; if (!_backLong) _backShort(); }
          return KeyEventResult.handled;
        }
        if (_verticalGuide && !_settingsOpen) {
          if (key == LogicalKeyboardKey.contextMenu) { if (event is KeyDownEvent) _contextSelectDown = (_verticalColumn==0 && _verticalRows.isNotEmpty)||_programmeHasFocus; if (event is KeyUpEvent && _contextSelectDown) { _contextSelectDown=false; unawaited(_withDialog(_programmeHasFocus?_programmeContext:_channelContext)); } return KeyEventResult.handled; }
          if ((_verticalColumn==0||_verticalColumn==1) && (key==LogicalKeyboardKey.select||key==LogicalKeyboardKey.enter)) return _guideOk(event,vertical:true);
          if (_verticalColumn == 0 && (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown)) { _guideChannelArrow(event,vertical:true); return KeyEventResult.handled; }
          if (event is KeyUpEvent) { if (_fastScroll) setState(() => _fastScroll = false); return KeyEventResult.handled; }
          if (event is KeyDownEvent || event is KeyRepeatEvent) {
            if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
              if (event is KeyRepeatEvent && !_fastScroll) setState(() => _fastScroll = true);
              _moveVertical(key == LogicalKeyboardKey.arrowDown ? 1 : -1);
            } else if (event is KeyDownEvent) {
              if (key == LogicalKeyboardKey.arrowRight) { if (_verticalColumn == -2) { setState(()=>_verticalColumn=-1); _scrollVerticalGroups(); } else if (_verticalColumn == -1) { _chooseVerticalGroup(enterChannels:true); } else { setState(() => _verticalColumn = (_verticalColumn + 1).clamp(0,2).toInt()); if (_verticalColumn == 1) _scrollVerticalBoth(); } }
              if (key == LogicalKeyboardKey.arrowLeft) { if (_verticalColumn > 0) { setState(() => _verticalColumn--); _scrollVerticalBoth(); } else if (_verticalColumn == 0) { _openVerticalGroups(); } else if (_verticalColumn == -1) { setState(()=>_verticalColumn=-2); } }
              if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) unawaited(_confirmVertical());
            }
          }
          return KeyEventResult.handled;
        }
        if (_preparingCatalog) {
          if (event is KeyDownEvent && key == LogicalKeyboardKey.arrowLeft && !_preview && !_showName) { _openVerticalGuide(); }
          if (event is KeyDownEvent && (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) && !_preview) { setState(() => _showName = !_showName); _hideLater(); }
          return KeyEventResult.handled;
        }
        if ((_preview || _verticalGuide) && _settingsOpen) {
          if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
            if (event is KeyDownEvent) _settingsSelectDown = true;
            if (event is KeyUpEvent && _settingsSelectDown) { _settingsSelectDown = false; unawaited(_withDialog(_activateSetting)); }
            return KeyEventResult.handled;
          }
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.handled;
          if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) { _moveSetting(key == LogicalKeyboardKey.arrowDown ? 1 : -1); }
          else if (key == LogicalKeyboardKey.arrowLeft) { _closeSettings(); }

          return KeyEventResult.handled;
        }
        if (_preview && _menuOpen) {
          if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
            if (event is KeyDownEvent) _menuSelectDown = true;
            if (event is KeyUpEvent && _menuSelectDown) { _menuSelectDown = false; unawaited(_activateMenu()); }
            return KeyEventResult.handled;
          }
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.handled;
          if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
            setState(() => _menuIndex = (_menuIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(0, _menuLabels.length - 1).toInt());
          } else if (key == LogicalKeyboardKey.arrowRight) { _closeMenu(); }

          return KeyEventResult.handled;
        }
        if (_preview && key == LogicalKeyboardKey.arrowLeft) {
          if (event is KeyDownEvent) { _leftLong = false; _leftHold?.cancel(); _leftHold = Timer(const Duration(milliseconds: 600), () { if (mounted) setState(() { _leftLong = true; if (!_groupFocus) { _inProgrammes = true; _stepProgramme(-1); } }); }); }
          if (event is KeyUpEvent) { _leftHold?.cancel(); _leftHold = null; if (!_leftLong) { if (_groupFocus) { setState(() { _menuOpen = true; _menuStatus = ''; }); } else if (!_inProgrammes) { setState(() => _groupFocus = true); _scrollGroup(); } else if (_onCurrentProgramme) { setState(() => _inProgrammes = false); } else { setState(() => _stepProgramme(-1)); } } }
          return KeyEventResult.handled;
        }
        if (_preview && !_groupFocus && (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter)) return _guideOk(event,vertical:false);
        if (key == LogicalKeyboardKey.contextMenu) {
          if (event is KeyDownEvent) _contextSelectDown = true;
          if (event is KeyUpEvent && _contextSelectDown) {
            _contextSelectDown = false;
            unawaited(_withDialog(_preview ? (_programmeHasFocus ? _programmeContext : _channelContext) : _options));
          }
          return KeyEventResult.handled;
        }
        if (_preview && !_groupFocus && (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown)) {
          _guideChannelArrow(event,vertical:false);
          return KeyEventResult.handled;
        }
        if (_preview && _groupFocus && (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown)) {
          if (event is KeyDownEvent || event is KeyRepeatEvent) { if (event is KeyRepeatEvent && !_fastScroll) setState(()=>_fastScroll=true); _selectGroup(_groupIndex+(key==LogicalKeyboardKey.arrowDown?1:-1)); }
          if (event is KeyUpEvent && _fastScroll) setState(()=>_fastScroll=false);
          return KeyEventResult.handled;
        }
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
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
              else { if (!_inProgrammes) { _inProgrammes=true; _stepProgramme(0); } else { _stepProgramme(1); } }
            });
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        if (key == LogicalKeyboardKey.arrowLeft) { if (_showName) { _stepBanner(-1); } else { _openVerticalGuide(); } return KeyEventResult.handled; }
        if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
          final delta = key == LogicalKeyboardKey.arrowUp ? 1 : -1;
          if (_showChannels) {
            final rows = _popupIndices;
            if (rows.isNotEmpty) setState(() => _highlightIndex = rows[(rows.indexOf(_highlightIndex) - delta).clamp(0, rows.length - 1).toInt()]);
            _scrollToHighlight();
          } else {
            final rows = _visibleIndices;
            if (rows.isNotEmpty) { final pos = rows.indexOf(_channelIndex); unawaited(_switchChannel(rows[(pos + delta + rows.length) % rows.length])); }
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
          setState(() { _technicalVisible = false; if (_bannerSeconds == 0 && _showName && _bannerProgramme == null) { _showName = false; } else { _showName = true; } _bannerProgramme = null; });
          _hideLater();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.escape && _showChannels) {
          _toggleChannels();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          if (_showName) { _stepBanner(1); return KeyEventResult.handled; }
          unawaited(_previousChannel());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }, child: Stack(fit: StackFit.expand, children: [
        if (_verticalGuide) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _ZoomAperture(verticalVideo)))),
        if (_verticalGuide) Positioned.fill(child:_verticalGuidePanel(verticalVideo)),
        if (_zooming && _zoomRect != null) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _ZoomAperture(_zoomRect!)))),
        if (_preview && !_zooming) const Positioned(left: 0, right: 0, top: 0, height: 16, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview && !_zooming) const Positioned(right: 0, left: 308, top: 16, height: 162, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview && !_zooming) const Positioned(left: 0, width: 20, top: 16, height: 162, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview && !_zooming) const Positioned(left: 0, right: 0, top: 178, bottom: 0, child: ColoredBox(color: Color(0xFF10151D))),
        if (_preview && !_tuned) const Positioned(left: 20, width: 288, top: 16, height: 162, child: ColoredBox(color: Color(0xFF242A36), child: Center(child: Text('Selecciona un canal', style: TextStyle(color: Colors.white70))))),
        if (_preview && !_zooming) Positioned(left: 328, right: 20, top: 16, height: 162, child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: _previewDetails())),
        if (_preview && !_zooming) Positioned(left: 20, right: 20, top: 184, bottom: 20, child: _previewGuide()),
        if (_player != null) Positioned(
          key: const ValueKey('vision-iptv-video'),
          top: _verticalGuide ? verticalVideo.top : _zoomRect?.top ?? (_preview ? 16 : 0), right: _zoomRect != null || _smallVideo ? null : 0,
          left: _verticalGuide ? verticalVideo.left : _zoomRect?.left ?? (_preview ? 20 : 0), bottom: _zoomRect != null || _smallVideo ? null : 0,
          width: _verticalGuide ? verticalVideo.width : _zoomRect?.width ?? (_preview ? 288 : null), height: _verticalGuide ? verticalVideo.height : _zoomRect?.height ?? (_preview ? 162 : null),
          child: SizedBox(key: _videoKey, child: Video(player: _player!))),
        if (_preview && !_zooming) const Positioned(left: 20, top: 16, width: 288, height: 162, child: IgnorePointer(child: CustomPaint(painter: _PreviewCornerMask()))),
        if (_verticalGuide) Positioned.fromRect(rect:verticalVideo,child:const IgnorePointer(child:CustomPaint(painter:_PreviewCornerMask()))),
        if (_showLoadingIndicator && _tuned && !_ready && !_failed && (_smallVideo || _autoFirstReady!=null)) Positioned(
          top: _verticalGuide ? verticalVideo.top + verticalVideo.height/2-14 : _preview ? 70 : 0, right: _smallVideo ? null : 0,
          left: _verticalGuide ? verticalVideo.left + verticalVideo.width/2-14 : _preview ? 140 : 0, bottom: _smallVideo ? null : 0,
          child: const Center(child: CircularProgressIndicator())),
        if (_failed) Positioned(top: _verticalGuide ? verticalVideo.top + 12 : _preview ? 70 : 0, right: _verticalGuide ? 20 : _preview ? null : 0,
          left: _verticalGuide ? verticalVideo.left : _preview ? 20 : 0, bottom: _smallVideo ? null : 0,
          child: const Center(child: Text('No se pudo reproducir el canal.'))),
        if (!_preview && !_verticalGuide && _showName && !_showChannels) Positioned(left: 24, right: 24, bottom: 24, child: _infoBanner()),
        if ((_preview || _verticalGuide) && _technicalVisible && _showName) Positioned(left: 20, bottom: 20, right: 20, child: ColoredBox(color: Colors.black87, child: Padding(padding: const EdgeInsets.all(12), child: Text(_technical, style: const TextStyle(color: Colors.white))))),
        if (_showChannels) Align(alignment: Alignment.centerLeft, child: SizedBox(
          width: 340,
          child: ColoredBox(color: const Color(0xEB000000),
            child: SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.all(16), child: Text('Canales IPTV', style: TextStyle(color: Colors.white, fontSize: 22))),
              Expanded(child: ListView.builder(
                controller: _channelScroll,
                itemExtent: 56,
                cacheExtent: 112, addAutomaticKeepAlives: false,
                itemCount: _popupIndices.length,
                itemBuilder: (_, row) {
                  final index = _popupIndices[row];
                  final channel = widget.channels[index];
                  final focused = index == _highlightIndex;
                  final current = index == _channelIndex;
                  return Container(
                    color: focused ? Colors.blue.shade700 : Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      SizedBox(width: 32, child: Text('${_channelNumber(index)}', style: const TextStyle(color: Colors.white70))),
                      SizedBox(width: 40, height: 32, child: _logo(channel).isEmpty
                        ? const Icon(Icons.tv, color: Colors.white70)
                        : Image.network(_logo(channel), cacheWidth: 128, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.tv, color: Colors.white70))),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_name(channel), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white))),
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

class _ZoomAperture extends CustomPainter {
  const _ZoomAperture(this.rect);
  final Rect rect;
  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()..addRect(Offset.zero & size);
    final inside = Path()..addRect(rect);
    canvas.drawPath(Path.combine(PathOperation.difference, outside, inside), Paint()..color = const Color(0xFF10151D));
  }
  @override
  bool shouldRepaint(covariant _ZoomAperture oldDelegate) => oldDelegate.rect != rect;
}

class _EpgChannelPicker extends StatefulWidget {
  const _EpgChannelPicker({required this.title, required this.ids, required this.names, required this.selectedId});
  final String title, selectedId;
  final List<String> ids;
  final Map<String, String> names;
  @override
  State<_EpgChannelPicker> createState() => _EpgChannelPickerState();
}
class _EpgChannelPickerState extends State<_EpgChannelPicker> {
  final _search = FocusNode();
  final _results = FocusNode();
  final _scroll = ScrollController();
  int _index = 0;
  late final Map<String, String> _searchKeys = {for (final id in widget.ids) id: '${widget.names[id]} $id'.toLowerCase()};
  late List<String> _filtered = widget.ids;
  late final TextEditingController _queryController;
  @override
  void initState() {
    super.initState();
    final initial = widget.title.trim().split(RegExp(r'\s+')).take(3).join(' ');
    _queryController = TextEditingController(text: initial);
    _filtered = _matches(initial);
  }
  List<String> _matches(String query) {
    final terms = query.toLowerCase().trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    return terms.isEmpty ? widget.ids : widget.ids.where((id) => terms.every((term) => _searchKeys[id]!.contains(term))).toList();
  }
  void _filter(String query) {
    setState(() { _filtered = _matches(query); _index = 0; });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }
  void _move(int delta) {
    final rows = _filtered;
    if (rows.isEmpty) return;
    setState(() => _index = (_index + delta).clamp(0, rows.length - 1).toInt());
    if (_scroll.hasClients) {
      final p = _scroll.position;
      _scroll.jumpTo((_index * 44.0 - p.viewportDimension / 2 + 22).clamp(0.0, p.maxScrollExtent).toDouble());
    }
  }
  @override
  void dispose() { _queryController.dispose(); _search.dispose(); _results.dispose(); _scroll.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    return AlertDialog(
      backgroundColor: const Color(0xFF1B202A), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), title: Text('Asignar EPG · ${widget.title}', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      content: SizedBox(width: 500, height: (MediaQuery.sizeOf(context).height - 150).clamp(180.0, 420.0).toDouble(), child: Column(children: [
        Focus(onKeyEvent: (_, e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.arrowDown) { _results.requestFocus(); return KeyEventResult.handled; }
          return KeyEventResult.ignored;
        }, child: TextField(controller: _queryController, focusNode: _search, style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search, color: Color(0xFF90CAF9)), hintText: 'Buscar canal EPG',
            filled: true, fillColor: const Color(0xFF242A36), isDense: true,
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: const BorderSide(color: Color(0xFF90CAF9))),
            suffixIcon: IconButton(onPressed: () { _queryController.clear(); _filter(''); }, icon: const Icon(Icons.clear, size: 18))),

          onSubmitted: (_) => _results.requestFocus(),
          onChanged: _filter)),
        Expanded(child: Focus(focusNode: _results, autofocus: true, onFocusChange: (_) => setState(() {}), onKeyEvent: (_, e) {
          final k = e.logicalKey;
          if (e is KeyDownEvent || e is KeyRepeatEvent) {
            if (k == LogicalKeyboardKey.arrowUp) { if (_index == 0) { _search.requestFocus(); } else { _move(-1); } return KeyEventResult.handled; }
            if (k == LogicalKeyboardKey.arrowDown) { _move(1); return KeyEventResult.handled; }
          }
          if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter) {
            if (e is KeyUpEvent && rows.isNotEmpty) Navigator.pop(context, rows[_index]);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }, child: ExcludeFocus(child: rows.isEmpty ? const Center(child: Text('No hay canales EPG disponibles')) : ListView.builder(
          controller: _scroll, itemExtent: 44, itemCount: rows.length, itemBuilder: (_, i) {
            final id = rows[i];
            final focused = _results.hasFocus && i == _index;
            final color = focused ? Colors.black : Colors.white;
            return GestureDetector(onTap: () => Navigator.pop(context, id), child: Container(
              margin: const EdgeInsets.only(bottom: 2), padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(color: focused ? const Color(0xFF90CAF9) : Colors.transparent, borderRadius: BorderRadius.circular(7)),
              child: Row(children: [
                Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.names[id] ?? id, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 13)),
                  Text(id, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: focused ? Colors.black87 : Colors.white70, fontSize: 11)),
                ])),
                if (id == widget.selectedId) Icon(Icons.check, color: color, size: 17),
              ])));
          })))),
      ])),
      actions: [TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        TextButton(style: _iptvDialogButtonStyle, onPressed: () => Navigator.pop(context, ''), child: const Text('Restablecer automática'))],
    );
  }
}

final _iptvDialogButtonStyle = ButtonStyle(
  backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused) ? const Color(0xFF90CAF9) : Colors.transparent),
  foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused) ? Colors.black : Colors.white),
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(7))),
);

Map<String, dynamic> _readIptvMap(String? value) {
  try { return Map<String, dynamic>.from(jsonDecode(value ?? '{}') as Map); } catch (_) { return {}; }
}

class _ProgrammeInfoDialog extends StatefulWidget {
  const _ProgrammeInfoDialog({required this.entries,required this.initial,required this.channelName,required this.channelLogo,required this.channelNumber,required this.onSelected});
  final List<_Programme> entries;
  final int initial,channelNumber;
  final String channelName,channelLogo;
  final ValueChanged<int> onSelected;
  @override State<_ProgrammeInfoDialog> createState()=>_ProgrammeInfoDialogState();
}
class _ProgrammeInfoDialogState extends State<_ProgrammeInfoDialog>{
  late int _index=widget.initial;
  final _scroll=ScrollController();
  final _focus=FocusNode();
  String _time(DateTime d){final t=d.toLocal();return '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}';}
  String _date(DateTime d){final t=d.toLocal();const days=['Lunes','Martes','Miércoles','Jueves','Viernes','Sábado','Domingo'];const months=['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];return '${days[t.weekday-1]}, ${t.day} de ${months[t.month-1]}';}
  void _move(int delta){final next=(_index+delta).clamp(0,widget.entries.length-1).toInt();if(next==_index)return;setState(()=>_index=next);widget.onSelected(next);if(_scroll.hasClients)_scroll.jumpTo(0);}
  @override void dispose(){_scroll.dispose();_focus.dispose();super.dispose();}
  @override Widget build(BuildContext context){
    final p=widget.entries[_index],now=DateTime.now();
    final live=!now.isBefore(p.start)&&now.isBefore(p.stop);
    final minutes=p.stop.difference(p.start).inMinutes;
    const blue=Color(0xFF90CAF9);
    return Dialog(backgroundColor:const Color(0xFF1B202A),insetPadding:const EdgeInsets.symmetric(horizontal:28,vertical:24),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14)),child:Focus(focusNode:_focus,autofocus:true,onKeyEvent:(_,event){
      final k=event.logicalKey;
      if(event is KeyDownEvent||event is KeyRepeatEvent){
        if(k==LogicalKeyboardKey.arrowLeft){_move(-1);return KeyEventResult.handled;}
        if(k==LogicalKeyboardKey.arrowRight){_move(1);return KeyEventResult.handled;}
        if(k==LogicalKeyboardKey.arrowUp||k==LogicalKeyboardKey.arrowDown){if(_scroll.hasClients){final pos=_scroll.position;_scroll.jumpTo((pos.pixels+(k==LogicalKeyboardKey.arrowDown?48:-48)).clamp(0.0,pos.maxScrollExtent).toDouble());}return KeyEventResult.handled;}
        if(event is KeyDownEvent&&(k==LogicalKeyboardKey.goBack||k==LogicalKeyboardKey.escape||k==LogicalKeyboardKey.browserBack||k==LogicalKeyboardKey.select||k==LogicalKeyboardKey.enter)){Navigator.pop(context);return KeyEventResult.handled;}
      }return KeyEventResult.ignored;
    },child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:900,maxHeight:490),child:Padding(padding:const EdgeInsets.all(20),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Row(children:[const Expanded(child:Text('Información del programa',style:TextStyle(color:Colors.white70,fontSize:14))),Text(_time(now),style:const TextStyle(color:blue,fontSize:15))]),
      const SizedBox(height:7),
      const Divider(color:Colors.white24),
      Expanded(child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
        SizedBox(width:30,child:Center(child:Icon(Icons.chevron_left,size:30,color:_index>0?blue:Colors.white24))),
        Flexible(flex:3,child:LayoutBuilder(builder:(_,constraints){
          final h=constraints.maxHeight;
          final posterHeight=(h*.575).clamp(0.0,212.75).toDouble();
          return Column(mainAxisAlignment:MainAxisAlignment.center,children:[
            if(p.poster.startsWith('http'))...[
              SizedBox(height:posterHeight,width:posterHeight*2/3,child:ClipRRect(borderRadius:BorderRadius.circular(10),child:Image.network(p.poster,key:ValueKey(p.poster),fit:BoxFit.cover,cacheHeight:480,errorBuilder:(_,__,___)=>const Icon(Icons.image_not_supported_outlined,color:Colors.white38,size:42)))),
              SizedBox(height:h*.025),
            ],
            SizedBox(height:(h*.15).clamp(0.0,62.0).toDouble(),width:112,child:widget.channelLogo.isNotEmpty?Image.network(widget.channelLogo,fit:BoxFit.contain,cacheWidth:256,errorBuilder:(_,__,___)=>const Icon(Icons.tv,color:Colors.white54)):const Icon(Icons.tv,color:Colors.white54)),
            const SizedBox(height:8),
          ]);
        })),const SizedBox(width:18),
        Expanded(flex:8,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(p.title,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white,fontSize:25,fontWeight:FontWeight.bold)),
          const SizedBox(height:5),Text('${_date(p.start)}',style:const TextStyle(color:blue,fontSize:14)),
          const SizedBox(height:5),Text('${_time(p.start)} – ${_time(p.stop)} · $minutes min',style:const TextStyle(color:Colors.white70,fontSize:14)),
          if(live)...[const SizedBox(height:6),Row(children:[const Text('En emisión',style:TextStyle(color:blue)),const Spacer(),Text('${p.stop.difference(now).inMinutes} min restantes',style:const TextStyle(color:Colors.white70,fontSize:12))]),const SizedBox(height:4),LinearProgressIndicator(value:(now.difference(p.start).inSeconds/p.stop.difference(p.start).inSeconds.clamp(1,99999999)).clamp(0.0,1.0).toDouble(),color:blue,backgroundColor:Colors.white24,minHeight:3)],
          const SizedBox(height:18),
          Expanded(child:Scrollbar(controller:_scroll,thumbVisibility:true,child:SingleChildScrollView(controller:_scroll,padding:const EdgeInsets.only(right:12),child:Text(p.description.isEmpty?'Sin información adicional.':p.description,style:const TextStyle(color:Colors.white,fontSize:15,height:1.35))))),
        ])),
        SizedBox(width:30,child:Center(child:Icon(Icons.chevron_right,size:30,color:_index<widget.entries.length-1?blue:Colors.white24))),
      ])),
      const Divider(color:Colors.white24),
      const SizedBox(height:7),
      Row(children:[
        Expanded(child:Text(_index>0?widget.entries[_index-1].title:'',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white70,fontSize:12))),
        Text('${_index+1} / ${widget.entries.length}',style:const TextStyle(color:blue,fontWeight:FontWeight.bold)),
        Expanded(child:Text(_index+1<widget.entries.length?widget.entries[_index+1].title:'',textAlign:TextAlign.right,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white70,fontSize:12))),
      ]),
      const SizedBox(height:11),const Center(child:Text('← Anterior   ·   Siguiente →   ·   Atrás: volver a la guía',style:TextStyle(color:Colors.white54,fontSize:11))),
    ]))))); 
  }
}

class _ChannelOrderDialog extends StatefulWidget {
  const _ChannelOrderDialog({required this.names, required this.original});
  final List<String> names;
  final int original;
  @override
  State<_ChannelOrderDialog> createState() => _ChannelOrderDialogState();
}
class _ChannelOrderDialogState extends State<_ChannelOrderDialog> {
  late int _position = widget.original;
  late final List<String> _names = List.of(widget.names);
  final _scroll = ScrollController();
  bool _selectDown = false;
  void _move(int delta) {
    final next = (_position + delta).clamp(0, _names.length - 1).toInt();
    if (next == _position) return;
    setState(() { _names.insert(next, _names.removeAt(_position)); _position = next; });
    _center();
  }
  void _center() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      _scroll.jumpTo((_position * 38.0 - p.viewportDimension / 2 + 19).clamp(0.0, p.maxScrollExtent).toDouble());
    });
  }
  @override
  void initState() { super.initState(); _center(); }
  @override
  void dispose() { _scroll.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFF1B202A), title: const Text('Mover canal'),
    content: SizedBox(width: 480, height: (MediaQuery.sizeOf(context).height - 150).clamp(160.0, 380.0).toDouble(),
      child: Focus(autofocus: true, onKeyEvent: (_, e) {
        final k = e.logicalKey;
        if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
          if (e is KeyDownEvent || e is KeyRepeatEvent) _move(k == LogicalKeyboardKey.arrowUp ? -1 : 1);
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter) {
          if (e is KeyDownEvent) _selectDown = true;
          if (e is KeyUpEvent && _selectDown) Navigator.pop(context, _position);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }, child: Column(children: [
        const Text('Arriba / Abajo: mover · OK: guardar · Atrás: cancelar'),
        Expanded(child: ListView.builder(controller: _scroll, itemExtent: 38, itemCount: _names.length, itemBuilder: (_, i) =>
          Container(margin: const EdgeInsets.only(bottom: 2), padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(color: i == _position ? const Color(0xFF90CAF9) : Colors.transparent, borderRadius: BorderRadius.circular(7)),
            alignment: Alignment.centerLeft,
            child: Text('${i+1} · ${_names[i]}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: i == _position ? Colors.black : Colors.white))))),
      ]))));
}
