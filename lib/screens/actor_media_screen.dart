import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../media/ids.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../media/library_query.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_person.dart';
import '../media/media_server_client.dart';
import '../mixins/paginated_item_loader.dart';
import '../mixins/standard_paginated_view.dart';
import '../utils/app_logger.dart';
import '../utils/error_message_utils.dart';
import '../utils/media_server_http_client.dart';
import '../utils/provider_extensions.dart';
import '../widgets/collapsible_text.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/optimized_media_image.dart';
import '../utils/media_image_helper.dart';
import '../i18n/app_locale_utils.dart';
import '../i18n/strings.g.dart';
import 'base_media_list_detail_screen.dart';
import 'focusable_detail_screen_mixin.dart';
import '../mixins/grid_focus_node_mixin.dart';
import '../focus/focusable_action_bar.dart';
import '../utils/platform_detector.dart';
import '../services/settings_service.dart';
import '../widgets/focusable_media_card.dart';
import '../widgets/media_details_sheet.dart';

/// Screen to browse all media featuring a specific actor.
class ActorMediaScreen extends StatefulWidget {
  final String actorName;
  final String personId;
  final String? actorThumb;
  final String? characterName;
  final String serverId;
  final String? serverName;
  final MediaBackend backend;

  const ActorMediaScreen({
    super.key,
    required this.actorName,
    required this.personId,
    this.actorThumb,
    this.characterName,
    required this.serverId,
    this.serverName,
    required this.backend,
  });

  @override
  State<ActorMediaScreen> createState() => _ActorMediaScreenState();
}

class _ActorMediaScreenState extends BaseMediaListDetailScreen<ActorMediaScreen>
    with
        GridFocusNodeMixin<ActorMediaScreen>,
        FocusableDetailScreenMixin<ActorMediaScreen>,
        PaginatedItemLoader<MediaItem, ActorMediaScreen>,
        PaginatedItemUpdatable<ActorMediaScreen>,
        StandardPaginatedView<MediaItem, ActorMediaScreen> {
  static const int _pageSize = 200;

  /// Keeps a long biography to a readable line length on wide layouts.
  static const double _biographyMaxWidth = 800;

  final AbortController _detailsAbort = AbortController();
  late final FocusNode _biographyFocusNode = FocusNode(debugLabel: 'person_biography');
  MediaPersonDetails _details = MediaPersonDetails.empty;
  String? _focusedCharacter;
  String? _focusedFilmId;
  final Map<String, String?> _characterCache = {};


  /// Whether the biography is truncated, so D-pad focus has a reason to stop
  /// on it (SELECT expands it) between the grid and the app bar.
  bool _biographyExpandable = false;

  @override
  MediaItem get mediaItem => MediaItem(
    id: '',
    backend: widget.backend,
    kind: MediaKind.unknown,
    serverId: widget.serverId,
    serverName: widget.serverName,
  );

  @override
  String get title => widget.actorName;

  @override
  String get emptyMessage => t.discover.noContentAvailable;

  @override
  bool get hasItems => totalSize > 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDetails());
  }

  @override
  void dispose() {
    _detailsAbort.abort();
    _biographyFocusNode.dispose();
    disposePagination();
    disposeFocusResources();
    super.dispose();
  }

  MediaServerClient get _mediaClient => context.getMediaClientForServer(ServerId(widget.serverId));

  /// The server may be offline (a cast tap from an offline detail): the header
  /// then shows the fallback avatar and the load reports the failure, instead
  /// of the lookup throwing during build.
  MediaServerClient? get _mediaClientOrNull => context.tryGetMediaClientForServer(ServerId(widget.serverId));

  /// Best-effort: the filmography is the page. A server that cannot describe
  /// the person, or a failed lookup, leaves the header as name and photo.
  Future<void> _loadDetails() async {
    final client = _mediaClientOrNull;
    if (client == null) return;
    try {
      final details = await client.fetchPersonDetails(widget.personId, abort: _detailsAbort);
      if (!mounted || details.isEmpty) return;
      setState(() => _details = details);
    } catch (error, stackTrace) {
      if (_detailsAbort.isAborted) return;
      appLogger.w('Person details unavailable for ${widget.actorName}', error: error, stackTrace: stackTrace);
    }
  }

  /// Born, died, and birthplace rows; the age goes with the death date for
  /// someone who has died, and with the birth date otherwise.
  List<({String label, String value})> _personFacts() {
    final details = _details;
    final locale = LocaleSettings.currentLocale.intlLocaleName;
    String format(DateTime date) => DateFormat.yMMMMd(locale).format(date);
    final age = details.ageOn(DateTime.now());
    final strings = t.discover.person;
    return [
      if (details.birthDate case final born?)
        (
          label: strings.born,
          value: age != null && details.deathDate == null
              ? strings.dateWithAge(date: format(born), age: age)
              : format(born),
        ),
      if (details.deathDate case final died?)
        (
          label: strings.died,
          value: age != null ? strings.dateWithAgeAtDeath(date: format(died), age: age) : format(died),
        ),
      if (details.birthPlace case final place?) (label: strings.birthplace, value: place),
    ];
  }

  void _focusBiography() => _biographyFocusNode.requestFocus();

  String? _characterFromRoles(MediaItem item) {
    for (final person in item.roles ?? const []) {
      if ((person.id != null && person.id == widget.personId) ||
          person.tag.trim().toLowerCase() == widget.actorName.trim().toLowerCase()) {
        final role = person.role?.trim();
        return role == null || role.isEmpty ? null : role;
      }
    }
    return null;
  }

  Future<void> _updateFocusedCharacter(MediaItem item) async {
    final id = item.id;
    if (_focusedFilmId != id) {
      setState(() {
        _focusedFilmId = id;
        _focusedCharacter = _characterCache[id] ?? _characterFromRoles(item);
      });
    }
    if (_characterCache.containsKey(id)) return;
    final inlineRole = _characterFromRoles(item);
    if (inlineRole != null) {
      _characterCache[id] = inlineRole;
      return;
    }
    final client = _mediaClientOrNull;
    if (client == null) return;
    try {
      final fullItem = await client.fetchItem(id);
      if (!mounted) return;
      final role = fullItem == null ? null : _characterFromRoles(fullItem);
      _characterCache[id] = role;
      if (_focusedFilmId == id) setState(() => _focusedCharacter = role);
    } catch (error, stackTrace) {
      appLogger.w('Actor role lookup failed for $id', error: error, stackTrace: stackTrace);
    }
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPage(int start, int size, AbortController? abort) {
    return _mediaClient.fetchPersonMediaPage(widget.personId, start: start, size: size, abort: abort);
  }

  @override
  Future<void> loadItems() {
    return loadStandardPaginatedItems(
      pageSize: _pageSize,
      errorMessageFor: (error, stackTrace) => localizedLoadErrorMessage(error, stackTrace, context: widget.actorName),
      onLoaded: (loadedCount, totalCount) {
        appLogger.d('Loaded $loadedCount of $totalCount items for actor: ${widget.actorName}');
        autoFocusFirstItemAfterLoad();
      },
    );
  }

  @override
  List<FocusableAction> getAppBarActions() {
    return [];
  }

  Widget _buildActorHeaderContent() {
    final theme = Theme.of(context);
    final mutedColor = theme.colorScheme.onSurfaceVariant;
    final facts = _personFacts();
    final biography = _details.biography;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(40),
                  child: OptimizedMediaImage(
                    client: _mediaClientOrNull,
                    imagePath: widget.actorThumb,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    imageType: ImageType.avatar,
                    fallbackIcon: Symbols.person_rounded,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: .start,
                    children: [
                      Text(
                        widget.actorName,
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: .bold),
                        maxLines: 2,
                        overflow: .ellipsis,
                      ),
                      if ((PlatformDetector.isTV() ? _focusedCharacter ?? (_focusedFilmId == null ? widget.characterName : null) : widget.characterName) != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          (PlatformDetector.isTV() ? _focusedCharacter ?? widget.characterName : widget.characterName)!,
                          style: theme.textTheme.bodyMedium?.copyWith(color: mutedColor),
                          maxLines: 1,
                          overflow: .ellipsis,
                        ),
                      ],
                      if (totalSize > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          t.discover.titleCount(n: totalSize),
                          style: theme.textTheme.bodySmall?.copyWith(color: mutedColor),
                        ),
                      ],
                      if (facts.isNotEmpty) const SizedBox(height: 4),
                      for (final fact in facts)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${fact.label}  ',
                                  style: TextStyle(color: mutedColor),
                                ),
                                TextSpan(text: fact.value),
                              ],
                            ),
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (biography != null && !PlatformDetector.isTV()) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: _biographyMaxWidth,
                  maxHeight: PlatformDetector.isTV() ? 92 : double.infinity,
                ),
                child: PlatformDetector.isTV()
                    ? SingleChildScrollView(
                        primary: false,
                        child: _buildBiographyText(biography, theme),
                      )
                    : _buildBiographyText(biography, theme),
              ),
            ],
          ],
        ),
    );
  }

  Widget _buildBiographyText(String biography, ThemeData theme) => CollapsibleText(
    text: biography,
    maxLines: PlatformDetector.isTV() ? 3 : 4,
    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
    focusNode: _biographyFocusNode,
    onOverflowChanged: (overflows) => setState(() => _biographyExpandable = overflows),
    onNavigateUp: PlatformDetector.isTV() ? () {} : navigateToAppBar,
    onNavigateDown: navigateToGrid,
    onNavigateLeft: () {},
    onNavigateRight: () {},
  );

  Widget _buildActorHeader() => SliverToBoxAdapter(child: _buildActorHeaderContent());

  // Read-only filmography preview: no playback or detail action buttons.
  Future<void> _showFilmographyInfo(MediaItem item) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return Dialog(
          backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.96),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Colors.white, width: 2),
          ),
          child: SizedBox(
            width: MediaQuery.sizeOf(dialogContext).width * 0.86,
            height: MediaQuery.sizeOf(dialogContext).height * 0.76,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 180,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: OptimizedMediaImage(
                        client: _mediaClientOrNull,
                        imagePath: item.thumbPath,
                        fit: BoxFit.cover,
                        imageType: ImageType.poster,
                      ),
                    ),
                  ),
                  const SizedBox(width: 26),
                  Expanded(
                    child: MediaDetailsSheet(
                      item: item,
                      description: item.summary,
                      genres: item.genres ?? const <String>[],
                      emphasizeSynopsis: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTvActorPanel() {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    // Fixed TV panel: keep the actor header stationary and reserve poster space.
    final panelHeight = screenSize.height * 0.90;
    final posterHeight = (screenSize.height * 0.34).clamp(160.0, 245.0);
    final posterWidth = posterHeight * 2 / 3;
    return SliverToBoxAdapter(
      child: Center(
        child: Container(
          width: screenSize.width * 0.94,
          height: panelHeight,
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildActorHeaderContent()),
              if (hasItems) ...[
                const SizedBox(height: 12),
                Text('Filmografía en mi biblioteca', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                SizedBox(
                  height: posterHeight + 20,
                  child: ClipRect(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      scrollDirection: Axis.horizontal,
                      itemCount: totalSize,
                      separatorBuilder: (_, _) => const SizedBox(width: 14),
                      itemBuilder: (context, index) {
                        final item = loadedItems[index];
                        if (item == null) {
                          ensureIndexLoaded(index, pageSize: _pageSize);
                          return SizedBox(width: posterWidth);
                        }
                        return SizedBox(
                          width: posterWidth,
                          height: posterHeight,
                          child: FocusableMediaCard(
                            key: ValueKey(item.globalKey),
                            item: item,
                            focusNode: getGridItemFocusNode(index, debugLabel: 'actor_filmography_$index'),
                            viewModeOverride: ViewMode.grid,
                            fullBleedImage: true,
                            disableScale: true,
                            onTap: () => unawaited(_showFilmographyInfo(item)),
                            onNavigateUp: null,
                            onBack: handleBackFromContent,
                            onFocusChange: (focused) {
                              trackGridItemFocus(index, focused);
                              if (focused) unawaited(_updateFocusedCharacter(item));
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return buildDetailScaffold(
      slivers: [
        if (!PlatformDetector.isTV())
          CustomAppBar(
            title: Text(widget.actorName),
            pinned: true,
            actions: buildFocusableAppBarActions(),
            onBackPressed: popFromAppBar,
          ),
        if (PlatformDetector.isTV()) _buildTvActorPanel() else _buildActorHeader(),
        ...buildStateSlivers(),
        if (hasItems && !PlatformDetector.isTV())
          buildSparseFocusableGrid(
            totalItems: totalSize,
            itemAt: (index) => loadedItems[index],
            onRefresh: updateItem,
            onItemTap: (index) {
              final item = loadedItems[index];
              if (item != null) unawaited(_showFilmographyInfo(item));
            },
            onSkeletonVisible: (index) => ensureIndexLoaded(index, pageSize: _pageSize),
            onFirstRowNavigateUp: _biographyExpandable ? _focusBiography : null,
          ),
      ],
    );
  }
}
