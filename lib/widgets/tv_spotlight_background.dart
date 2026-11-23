import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../media/media_item.dart';
import '../media/media_backend.dart';
import '../media/media_item_types.dart';
import '../media/media_server_client.dart';
import '../services/device_performance.dart';
import '../utils/content_utils.dart';
import '../utils/formatters.dart';
import '../utils/layout_constants.dart';
import '../utils/media_image_helper.dart';
import '../services/settings_service.dart';
import '../utils/tone_mapped_logo_image.dart';
import 'cycling_media_backdrop.dart';
import 'ambient_spotlight_tint.dart';
import 'fitting_title_text.dart';
import 'fitted_metadata_line.dart';
import 'settings_builder.dart';
import 'media_rating_badge.dart';
import 'optimized_media_image.dart' show ClearLogoImage, blurArtwork;
import 'rasterized_gradient.dart';
import 'plex_trailer_preview.dart';

class TvSpotlightBackground extends StatelessWidget {
  final MediaItem? item;
  final MediaServerClient? client;
  final bool hideSpoilers;
  final double contentBottom;
  final double? contentTop;
  final double? contentLeft;
  final bool compact;
  final bool showInfo;
  final String? Function(String? artworkPath)? localArtworkPathResolver;
  final bool allowNetwork;
  final bool allowTrailerPreview;
  final bool detailTrailerArtworkLayout;

  /// Optional caller-owned fact appended to the existing metadata line.
  final Widget? metadataTrailing;
  final Widget? metadataBelow;

  const TvSpotlightBackground({
    super.key,
    required this.item,
    required this.client,
    this.hideSpoilers = false,
    this.contentBottom = 360,
    this.contentTop,
    this.contentLeft,
    this.compact = false,
    this.showInfo = true,
    this.localArtworkPathResolver,
    this.allowNetwork = true,
    this.allowTrailerPreview = true,
    this.detailTrailerArtworkLayout = false,
    this.metadataTrailing,
    this.metadataBelow,
  });

  double _scale(BuildContext context) => TvLayoutConstants.scaleOf(context);

  // These two gradients pre-multiply the alpha of the original pairs of
  // linear masks. They are created once, not recalculated for each title.
  // Sampling at 1/100 of the artwork width/height closely tracks the
  // original piecewise-linear product without extra compositing passes.
  static final LinearGradient _movieFanartHorizontalMask = _combinedFanartMask(
    const [0.0, 0.16, 0.27, 0.43, 0.59],
    const [0.0, 0.0, 0.2, 0.7, 1.0],
    const [0.0, 0.42, 0.60, 0.82],
    const [1.0, 0.8, 0.3333333333, 0.0],
    horizontal: true,
  );

  static final LinearGradient _movieFanartVerticalMask = _combinedFanartMask(
    const [0.0, 0.14, 0.30, 0.44],
    const [0.0, 166 / 255, 240 / 255, 1.0],
    const [0.0, 0.55, 0.75, 0.96],
    const [1.0, 192 / 255, 77 / 255, 0.0],
    horizontal: false,
  );

  static LinearGradient _combinedFanartMask(
    List<double> firstStops,
    List<double> firstAlpha,
    List<double> secondStops,
    List<double> secondAlpha, {
    required bool horizontal,
  }) {
    double sample(List<double> stops, List<double> alphas, double position) {
      if (position <= stops.first) return alphas.first;
      for (var i = 1; i < stops.length; i++) {
        if (position <= stops[i]) {
          final t = (position - stops[i - 1]) / (stops[i] - stops[i - 1]);
          return alphas[i - 1] + (alphas[i] - alphas[i - 1]) * t;
        }
      }
      return alphas.last;
    }

    final stops = List<double>.generate(101, (i) => i / 100);
    final colors = [
      for (final position in stops)
        Colors.white.withValues(
          alpha: sample(firstStops, firstAlpha, position) *
              sample(secondStops, secondAlpha, position),
        ),
    ];
    return LinearGradient(
      begin: horizontal ? Alignment.centerLeft : Alignment.topCenter,
      end: horizontal ? Alignment.centerRight : Alignment.bottomCenter,
      colors: colors,
      stops: stops,
    );
  }


  @override
  Widget build(BuildContext context) => AmbientSpotlightTint(
    item: item,
    client: client,
    allowNetwork: allowNetwork,
    localArtworkPathResolver: localArtworkPathResolver,
    childBuilder: _buildSpotlight,
  );

  Widget _buildSpotlight(BuildContext context) {
    final media = item;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    // The gradients never differ between spotlight items, so only the artwork
    // cross-fades by image paint alpha. Keeping the gradients outside the
    // rotating layer avoids full-screen saveLayers on low-end TVs.
    final size = MediaQuery.sizeOf(context);
    final containerAspect = size.width / size.height;
    final fallbackPaths = media == null
        ? const <String>[]
        : <String>[...media.heroArtCandidates(containerAspectRatio: containerAspect), ?media.thumbPath];
    return SettingValueBuilder<bool>(
      pref: SettingsService.tvCornerSpotlightBackdrop,
      builder: (context, cornerBackdrop, _) {
        final backdropSize = cornerBackdrop || detailTrailerArtworkLayout
            ? Size(size.width * 0.68, size.height * 0.72)
            : size;
        // Keep artwork entirely out of the widget tree during a shared
        // trailer session for this same title. In particular, the new detail
        // route must not paint a fresh fanart frame behind its AndroidView.
        final backdrop = ValueListenableBuilder<String?>(
          valueListenable: PlexTrailerPreview.activeTrailerUrl,
          builder: (context, activeUrl, _) => ValueListenableBuilder<bool>(
            valueListenable: PlexTrailerPreview.trailerFinished,
            builder: (context, finished, _) {
              if (activeUrl != null && !finished &&
                  PlexTrailerPreview.isActiveFor(media)) {
                return const SizedBox.expand();
              }
                return CyclingMediaBackdrop(
          mediaKey: media?.globalKey,
          imagePaths: media?.heroRotationPaths(containerAspectRatio: containerAspect) ?? const [],
          fallbackImagePaths: fallbackPaths,
          client: client,
          localArtworkPathResolver: localArtworkPathResolver == null ? null : (path) => localArtworkPathResolver!(path),
          allowNetwork: allowNetwork,
          // Always request at full-screen size: the corner box only crops the
          // layout. A mode-dependent size would change the transcode URL and
          // cold-start every cached backdrop when the setting is toggled.
          width: size.width,
          height: size.height,
          fallbackColor: media == null ? bgColor : Theme.of(context).colorScheme.surfaceContainerHighest,
                );
            },
          ),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: SettingValueBuilder<bool>(
                pref: SettingsService.plexTrailerPreview,
                builder: (context, trailerPreview, _) {
                  final showTrailer = trailerPreview && allowTrailerPreview &&
                      media != null && client != null && Platform.isAndroid;
                  if (showTrailer) {
                    // Prepare the artwork layer before the new route paints.
                    // The native player reports when its replacement surface
                    // has rendered the first frame.
                    PlexTrailerPreview.prepareForRoute(ModalRoute.of(context));
                  }
                  if (cornerBackdrop || detailTrailerArtworkLayout) {
                    return _buildCornerBackdrop(backdropSize, backdrop, media, client, showTrailer);
                  }
                  // Full-artwork mode must also host the shared trailer player.
                  // Keep it in the same top-right spotlight area so enabling
                  // or disabling the corner-artwork layout never disables trailers.
                  // Build the expensive blurred-artwork widget once per
                  // spotlight update, not on every trailer state notification.
                  // The child stays unmounted while the native trailer is
                  // active, preserving the no-fanart-flash behaviour.
                  final blurredBackdrop = blurArtwork(backdrop);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (showTrailer)
                        ValueListenableBuilder<String?>(
                          valueListenable: PlexTrailerPreview.activeTrailerUrl,
                          child: blurredBackdrop,
                          builder: (context, activeUrl, artwork) => ValueListenableBuilder<bool>(
                            valueListenable: PlexTrailerPreview.trailerFinished,
                            child: artwork,
                            builder: (context, finished, cachedArtwork) =>
                                activeUrl != null && !finished
                                    ? const ColoredBox(color: Colors.black)
                                    : cachedArtwork!,
                          ),
                        )
                      else
                        blurredBackdrop,
                      if (showTrailer)
                        Align(
                          alignment: Alignment.topRight,
                          child: SizedBox(
                            width: backdropSize.width,
                            height: backdropSize.height,
                            child: PlexTrailerPreview(
                              key: ValueKey(media!.globalKey),
                              item: media,
                              client: client!,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            _buildHorizontalScrim(bgColor),
            RasterizedGradient(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // Hard stop at the clear point so neither ramp blends toward
                // the other's color while fading out.
                colors: [
                  Colors.black.withValues(alpha: 0.45),
                  Colors.black.withValues(alpha: 0),
                  bgColor.withValues(alpha: 0),
                  bgColor.withValues(alpha: 0.96),
                ],
                stops: const [0.0, 0.38, 0.38, 1.0],
              ),
            ),
            // Movie details only: a second, uncropped fanart floats at the
            // lower-right corner and slightly overlaps the unchanged trailer.
            // It is independent of the native video surface and never changes
            // its bounds or shared playback session.
            if (detailTrailerArtworkLayout && media != null)
              ValueListenableBuilder<String?>(
                valueListenable: PlexTrailerPreview.activeTrailerUrl,
                builder: (context, activeUrl, _) => ValueListenableBuilder<bool>(
                  valueListenable: PlexTrailerPreview.surfaceReady,
                  builder: (context, surfaceReady, _) => ValueListenableBuilder<bool>(
                    valueListenable: PlexTrailerPreview.trailerFinished,
                    builder: (context, finished, _) => AnimatedOpacity(
                    opacity: activeUrl != null && surfaceReady && !finished ? 1 : 0,
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                    child: Transform.translate(
                      // Center the 42.4%-wide artwork box in the rightmost 40% of the TV.
                      // Target center = 80% of screen width (synopsis ends near 60%).
                      // Center the visible contained fanart at 70% of the screen width.
                      // Box center before translation: 100% - (42.4% / 2) = 78.8%.
                      offset: Offset(-size.width * 0.088, -size.height * 0.035),
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: SizedBox(
                        width: size.width * 0.424,
                        height: size.height * 0.36,
                        child: IgnorePointer(
                          // The contained artwork does not fill this wide box.
                          // Start the left fade inside the actual image area,
                          // rather than wasting it in the empty box margin.
                          // Precombine the horizontal and vertical alpha ramps.
                          // Four linear masks become two; radial feathers stay
                          // unchanged to preserve the original silhouette.
                          child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: _movieFanartHorizontalMask.createShader,
                            child: ShaderMask(
                              blendMode: BlendMode.dstIn,
                              shaderCallback: _movieFanartVerticalMask.createShader,
                              child: ShaderMask(
                                blendMode: BlendMode.dstIn,
                                shaderCallback: (rect) => const RadialGradient(
                                  center: Alignment(0.40, 0.48),
                                  radius: 1.20,
                                  colors: [Colors.white, Colors.white, Color(0xBFFFFFFF), Colors.transparent],
                                  stops: [0.0, 0.35, 0.68, 1.0],
                                ).createShader(rect),
                                child: ShaderMask(
                                  blendMode: BlendMode.dstIn,
                                  shaderCallback: (rect) => const RadialGradient(
                                    center: Alignment(0.02, 0.54),
                                    radius: 1.22,
                                    colors: [Colors.white, Colors.white, Color(0xD9FFFFFF), Colors.transparent],
                                    stops: [0.0, 0.38, 0.68, 1.0],
                                  ).createShader(rect),
                              child: CyclingMediaBackdrop(
                                mediaKey: media.globalKey,
                                imagePaths: media.heroRotationPaths(containerAspectRatio: containerAspect),
                                fallbackImagePaths: fallbackPaths,
                                client: client,
                                localArtworkPathResolver: localArtworkPathResolver == null
                                    ? null
                                    : (path) => localArtworkPathResolver!(path),
                                allowNetwork: allowNetwork,
                                width: size.width * 0.424,
                                height: size.height * 0.36,
                                fit: BoxFit.contain,
                                alignment: Alignment.bottomCenter,
                                fallbackColor: Colors.transparent,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ),
                  ),
                ),
              ),
            if (media != null && showInfo)
              Positioned(
                left: contentLeft ?? TvLayoutConstants.horizontalInset,
                right: MediaQuery.sizeOf(context).width * 0.43,
                top: contentTop,
                bottom: contentBottom,
                // The info block still cross-fades via AnimatedSwitcher, but its
                // saveLayers are bounded to the text region, not the screen.
                child: AnimatedSwitcher(
                  duration: DevicePerformance.reducedDuration(const Duration(milliseconds: 280)),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeOutCubic,
                  // Expand instead of the default loose centered Stack so the
                  // info keeps filling the region and bottom-left aligning.
                  layoutBuilder: (currentChild, previousChildren) =>
                      Stack(fit: StackFit.expand, children: [...previousChildren, ?currentChild]),
                  child: KeyedSubtree(
                    key: ValueKey(media.globalKey),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        if (!constraints.hasBoundedHeight || constraints.maxHeight <= 0 || constraints.maxWidth <= 0) {
                          return Align(alignment: .bottomLeft, child: _buildInfo(context, media, constraints.maxWidth));
                        }

                        return Align(
                          alignment: .bottomLeft,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: .bottomLeft,
                            child: SizedBox(
                              width: constraints.maxWidth,
                              child: _buildInfo(context, media, constraints.maxWidth),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Corner spotlight: artwork pinned to the top-right corner, left and
  /// bottom edges feathered into the scaffold background so the info block
  /// sits on a calm surface instead of the image.
  Widget _buildCornerBackdrop(Size backdropSize, Widget backdrop, MediaItem? media, MediaServerClient? client, bool trailerPreview) {
    return Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        width: backdropSize.width,
        height: backdropSize.height,
        child: ShaderMask(
          shaderCallback: (rect) =>
              const LinearGradient(colors: [Colors.transparent, Colors.white], stops: [0.0, 0.35]).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: ShaderMask(
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0.0, 0.55, 1.0],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: ValueListenableBuilder<String?>(
              valueListenable: PlexTrailerPreview.activeTrailerUrl,
              builder: (context, activeUrl, _) => ValueListenableBuilder<bool>(
                valueListenable: PlexTrailerPreview.trailerFinished,
                builder: (context, finished, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    // The native SurfaceView may disappear for a frame when
                    // switching routes. Keep artwork out of its backing layer
                    // throughout active playback, not only until ready.
                    // Omit the artwork widget entirely during playback.
                    // The black backing is deliberate for the brief native
                    // surface handoff; do not paint the fanart underneath it.
                    if (trailerPreview && activeUrl != null && !finished)
                      const ColoredBox(color: Colors.black)
                    else
                      backdrop,
                    if (trailerPreview && media != null && client != null && Platform.isAndroid)
                      PlexTrailerPreview(key: ValueKey(media.globalKey), item: media, client: client),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontalScrim(Color bgColor) {
    return RasterizedGradient(
      gradient: LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [bgColor.withValues(alpha: 0.86), bgColor.withValues(alpha: 0.32), bgColor.withValues(alpha: 0)],
        stops: const [0.0, 0.56, 1.0],
      ),
    );
  }

  Widget _buildInfo(BuildContext context, MediaItem media, double width) {
    final scale = _scale(context);
    final colorScheme = Theme.of(context).colorScheme;
    final shouldHideSpoiler = hideSpoilers && media.shouldHideSpoiler;
    final summary = shouldHideSpoiler ? null : media.summary;
    final title = media.grandparentTitle ?? media.displayTitle;

    return Column(
      crossAxisAlignment: .start,
      mainAxisSize: .min,
      children: [
        _buildLogoOrTitle(context, media, title, width),
        SizedBox(height: _sectionGap(scale)),
        _buildMetadataLine(context, media),
        if (metadataBelow != null) ...[
          SizedBox(height: _sectionGap(scale) * 0.65),
          metadataBelow!,
        ],
        if (summary != null && summary.isNotEmpty) ...[
          SizedBox(height: _sectionGap(scale)),
          Text(
            summary,
            maxLines: compact ? 3 : 4,
            overflow: .ellipsis,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.78),
              fontSize: _summaryFontSize(scale),
              height: compact ? 1.34 : 1.45,
            ),
          ),
        ] else if (shouldHideSpoiler && media.isEpisode) ...[
          SizedBox(height: _sectionGap(scale)),
          Text(
            media.title ?? '',
            maxLines: 2,
            overflow: .ellipsis,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.72),
              fontSize: _summaryFontSize(scale),
              height: compact ? 1.34 : 1.45,
            ),
          ),
        ],
      ],
    );
  }

  /// The logo is contained within its slot; the title fallback gets
  /// [ClearLogoImage.fallbackWidthFor] of the info block's [availableWidth]
  /// at the slot's height (#1796).
  Widget _buildLogoOrTitle(BuildContext context, MediaItem media, String title, double availableWidth) {
    final theme = Theme.of(context);
    // The spotlight scrim washes artwork toward the scaffold background, so
    // light themes recolor light-toned logos to stay visible.
    final logoToneTarget = logoToneTargetFor(
      surface: theme.scaffoldBackgroundColor,
      foreground: theme.colorScheme.onSurface,
    );
    final scale = _scale(context);
    final logoPath = media.clearLogoPath;
    final logoWidth = math.min(_logoWidth(scale), availableWidth);
    final logoHeight = _logoHeight(scale);
    final width = ClearLogoImage.fallbackWidthFor(logoWidth: logoWidth, available: availableWidth);
    if (logoPath == null || logoPath.isEmpty) {
      return SizedBox(width: width, height: logoHeight, child: _buildTitle(context, title));
    }
    final pixelRatio = MediaImageHelper.artworkPixelRatio(context, imageType: ImageType.heroLogo);
    final (logoMemWidth, logoMemHeight) = MediaImageHelper.getMemCacheDimensions(
      displayWidth: (logoWidth * pixelRatio).round(),
      displayHeight: (logoHeight * pixelRatio).round(),
      imageType: ImageType.heroLogo,
    );

    final localLogoPath = localArtworkPathResolver?.call(logoPath);
    if (localLogoPath != null && File(localLogoPath).existsSync()) {
      final bounded = MediaImageHelper.boundedDecode(
        FileImage(File(localLogoPath)),
        memWidth: logoMemWidth,
        memHeight: logoMemHeight,
      );
      return SizedBox(
        width: width,
        height: logoHeight,
        child: Align(
          alignment: .centerLeft,
          child: blurArtwork(
            Image(
              image: logoToneTarget == null
                  ? bounded
                  : ToneMappedLogoImage(bounded, target: logoToneTarget, remapMixed: false),
              width: logoWidth,
              height: logoHeight,
              fit: BoxFit.contain,
              filterQuality: MediaImageHelper.artworkFilterQuality(context, ImageType.heroLogo),
              alignment: .centerLeft,
              // Replaces the image under Align's loose constraints, so it
              // takes the whole title slot rather than the logo's.
              errorBuilder: (context, error, stackTrace) => SizedBox.expand(child: _buildTitle(context, title)),
            ),
            sigma: 10,
            clip: false,
          ),
        ),
      );
    }

    return ClearLogoImage(
      client: client,
      logoPath: logoPath,
      width: logoWidth,
      height: logoHeight,
      fallbackWidth: width,
      fadeInDuration: DevicePerformance.reducedDuration(const Duration(milliseconds: 200)),
      logoToneTarget: logoToneTarget,
      fallbackBuilder: (context) => _buildTitle(context, title),
    );
  }

  Widget _buildTitle(BuildContext context, String title) {
    final scale = _scale(context);
    final colorScheme = Theme.of(context).colorScheme;
    return FittingTitleText(
      title,
      style: Theme.of(context).textTheme.displaySmall?.copyWith(
        color: colorScheme.onSurface,
        fontSize: _titleFontSize(scale),
        fontWeight: .w700,
        shadows: [Shadow(color: colorScheme.surface.withValues(alpha: 0.8), blurRadius: 12)],
      ),
    );
  }

  Widget _buildMetadataLine(BuildContext context, MediaItem media) {
    final scale = _scale(context);
    final colorScheme = Theme.of(context).colorScheme;
    final episodeLabel = formatSeasonEpisodeLabel(media.parentIndex, media.index);
    final textStyle = TextStyle(
      color: colorScheme.onSurface,
      fontSize: _metadataFontSize(scale),
      fontWeight: .w700,
      letterSpacing: 0.1,
    );

    final parts = <MetadataLinePart>[];
    if (media.isEpisode && episodeLabel != null) parts.add(MetadataLineText(episodeLabel, dropPriority: 0));
    if (media.isMovie) {
      parts.add(MetadataLineText(t.discover.movie, dropPriority: 3));
    } else if (media.isShow) {
      parts.add(MetadataLineText(t.discover.tvShow, dropPriority: 3));
    }
    // Hub listings carry the scalar rating pair, so the dashboard spotlight
    // shows every score the shelf request already returned — no per-item
    // hydration to lengthen it.
    final ratings = mediaRatingsFor(media);
    if (ratings.isNotEmpty) parts.add(MetadataLineRatings(ratings, dropPriority: 4));
    if (media.contentRating != null) {
      parts.add(MetadataLineText(formatContentRating(media.contentRating!), dropPriority: 2));
    }
    if (media.durationMs != null) {
      parts.add(MetadataLineText(formatDurationTextual(media.durationMs!), dropPriority: 1));
    }
    if (media.isEpisode && media.originallyAvailableAt != null) {
      parts.add(MetadataLineText(formatFullDate(media.originallyAvailableAt!), dropPriority: 0));
    } else if (media.year != null) {
      parts.add(MetadataLineText(media.year.toString(), dropPriority: 0));
    }

    final line = parts.isEmpty
        ? null
        : FittedMetadataLine(
            textStyle: textStyle,
            parts: parts,
            ratingIconSize: textStyle.fontSize,
            ratingSpacing: 4 * scale,
            ratingEntrySpacing: 12 * scale,
          );
    final trailing = metadataTrailing;
    if (trailing == null) return line ?? const SizedBox.shrink();
    if (line == null) return trailing;
    // The trailing fact is caller-owned and always shown; the line fits
    // itself into whatever width the trailing widget leaves over.
    return Row(
      mainAxisSize: .min,
      children: [
        Flexible(child: line),
        Text(FittedMetadataLine.separator, maxLines: 1, style: textStyle),
        trailing,
      ],
    );
  }

  double _sectionGap(double scale) => (compact ? 10 : 16) * scale;

  double _logoWidth(double scale) =>
      (compact ? TvLayoutConstants.compactHeroLogoWidth : TvLayoutConstants.heroLogoWidth) * scale;

  double _logoHeight(double scale) =>
      (compact ? TvLayoutConstants.compactHeroLogoHeight : TvLayoutConstants.heroLogoHeight) * scale;

  double _titleFontSize(double scale) => (compact ? 36 : 54) * scale;

  double _metadataFontSize(double scale) => (compact ? 16 : 18) * scale;

  double _summaryFontSize(double scale) => (compact ? 18 : 20) * scale;
}
