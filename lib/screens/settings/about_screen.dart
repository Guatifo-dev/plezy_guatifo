import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_section.dart';
import '../../i18n/strings.g.dart';
import '../../theme/mono_tokens.dart';
import 'licenses_screen.dart';
import '../../utils/external_url.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String _visionVersion = '1.0.1';

  @override
  Widget build(BuildContext context) {
    const gitCommit = String.fromEnvironment('GIT_COMMIT');
    final shortCommit = gitCommit.length >= 7 ? gitCommit.substring(0, 7) : gitCommit;
    final muted = tokens(context).textMuted;
    return FocusedScrollScaffold(
      title: Text(t.about.title),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/plezyvision_about.png', width: 72, height: 72),
                    const SizedBox(height: 6),
                    Text('Plezy Vision', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text('Versión $_visionVersion', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: muted)),
                    if (shortCommit.isNotEmpty)
                      Text('Commit: $shortCommit', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted)),
                    const SizedBox(height: 10),
                    Text(
                      'Cliente para Plex basado en Plezy, con navegación visual, tráileres automáticos e insignias multimedia.\n'
                      'Proyecto independiente de código abierto, basado en Plezy de edde746.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 5),
                    Text('Licencia GNU GPL-3.0', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SettingsGroup(
                margin: EdgeInsets.zero,
                children: [
                  for (final entry in const [
                    ('Proyecto original · Plezy', 'https://github.com/edde746/plezy'),
                    ('Código fuente · PlezyVision', 'https://github.com/Guatifo-dev/plezy_guatifo'),
                    ('Licencia GNU GPL-3.0', 'https://github.com/edde746/plezy/blob/main/LICENSE'),
                  ])
                    FocusableListTile(
                      leading: const AppIcon(Symbols.open_in_new_rounded, fill: 1),
                      title: Text(entry.$1),
                      trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                      onTap: () async {
                        final opened = await openExternalUrl(Uri.parse(entry.$2));
                        if (!opened && context.mounted) {
                          await Clipboard.setData(ClipboardData(text: entry.$2));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('No se pudo abrir el enlace; URL copiada')),
                            );
                          }
                        }
                      },
                    ),
                  FocusableListTile(
                    dense: true,
                    leading: const AppIcon(Symbols.description_rounded, fill: 1),
                    title: Text(t.about.openSourceLicenses),
                    trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                    onTap: () {
                      Navigator.push(context, MaterialPageRoute(builder: (context) => const LicensesScreen()));
                    },
                  ),
                ],
              ),
            ]),
          ),
        ),
      ],
    );
  }
}
