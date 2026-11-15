import 'package:flutter/material.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../i18n/strings.g.dart';
import '../../theme/mono_tokens.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String _visionVersion = '1.0.1';

  @override
  Widget build(BuildContext context) {
    const gitCommit = String.fromEnvironment('GIT_COMMIT');
    final shortCommit = gitCommit.length >= 7 ? gitCommit.substring(0, 7) : gitCommit;
    final muted = tokens(context).textMuted;
    final theme = Theme.of(context);
    Widget feature(IconData icon, String title, String detail) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(icon, size: 19, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 4),
          Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ]),
      ),
    );

    return FocusedScrollScaffold(
      title: const Text('Acerca de'),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: 650,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Image.asset('assets/plezyvision_about.png', width: 76, height: 76),
                      const SizedBox(width: 16),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('PlezyVision', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                        Text('Versión ' + _visionVersion + (shortCommit.isEmpty ? '' : ' · Commit: ' + shortCommit),
                          style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                        Text('Cliente multimedia para Plex',
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary)),
                      ]),
                    ]),
                    const SizedBox(height: 18),
                    Text('Tu biblioteca, otra forma de disfrutarla',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('PlezyVision es una adaptación personalizada de Plezy, diseñada para ofrecer '
                      'una experiencia cinematográfica en Fire TV, con navegación visual y acceso '
                      'directo a tu biblioteca Plex.',
                      textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 18),
                    Row(children: [
                      feature(Icons.play_circle_outline, 'Tráileres automáticos', 'Vista previa al seleccionar títulos'),
                      const SizedBox(width: 10),
                      feature(Icons.photo_library_outlined, 'Exploración visual', 'Fanart, películas y series'),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      feature(Icons.high_quality_outlined, 'Insignias multimedia', '4K, HDR y audio avanzado'),
                      const SizedBox(width: 10),
                      feature(Icons.tv_outlined, 'Experiencia Fire TV', 'Navegación adaptada al mando'),
                    ]),
                    const SizedBox(height: 16),
                    Text('Proyecto independiente basado en Plezy de edde746 · GNU GPL-3.0',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
