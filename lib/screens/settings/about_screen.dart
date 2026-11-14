import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_section.dart';
import '../../i18n/strings.g.dart';
import '../../theme/mono_tokens.dart';
import 'licenses_screen.dart';
import '../../utils/external_url.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static final Future<PackageInfo> _packageInfoFuture = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    const appName = 'Plezy Vision';

    return FutureBuilder<PackageInfo>(
      future: _packageInfoFuture,
      builder: (context, snapshot) {
        final appVersion = snapshot.data?.version ?? '';
        const gitCommit = String.fromEnvironment('GIT_COMMIT');
        final shortCommit = gitCommit.length >= 7 ? gitCommit.substring(0, 7) : gitCommit;
        return FocusedScrollScaffold(
          title: Text(t.about.title),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  Center(
                    child: Column(
                      children: [
                        const SizedBox(height: 24),
                        Image.asset('assets/plezy.png', width: 80, height: 80),
                        const SizedBox(height: 16),
                        Text(appName, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: .bold)),
                        const SizedBox(height: 8),
                        Text(
                          t.about.versionLabel(version: appVersion),
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens(context).textMuted),
                        ),
                        if (gitCommit.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Commit: $shortCommit',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                tooltip: 'Copiar SHA completo',
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.copy_rounded, size: 16),
                                onPressed: () {
                                  Clipboard.setData(const ClipboardData(text: gitCommit));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('SHA del commit copiado')),
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 24),
                        Text(
                          t.about.appDescription,
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),
                  Text(
                    'Plezy Vision es un cliente multimedia orientado a Plex Media Server, basado en el proyecto de código abierto Plezy, creado por edde746. '
                    'Incluye mejoras de navegación, presentación de contenido, tráileres e información de audio y vídeo. '
                    'Estas modificaciones se han desarrollado y probado exclusivamente con Plex Media Server. '
                    'El código original conserva soporte para Jellyfin y Emby, pero las nuevas funcionalidades no se han verificado con esos servidores. '
                    'Es un proyecto independiente, no afiliado oficialmente a Plex ni desarrollado, respaldado o mantenido por el autor original de Plezy.'
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Text('Código bajo licencia GNU GPL-3.0. Se conservan los avisos legales y la licencia del proyecto original.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted),
                  ),
                  const SizedBox(height: 24),
                  SettingsGroup(
                    margin: EdgeInsets.zero,
                    children: [
                      for (final entry in const [
                        ('Proyecto original: Plezy — edde746', 'https://github.com/edde746/plezy'),
                        ('Código fuente: Plezy Vision — Guatifo-dev', 'https://github.com/Guatifo-dev/plezy_guatifo'),
                        ('Licencia GNU GPL-3.0', 'https://github.com/edde746/plezy/blob/main/LICENSE'),
                      ])
                        FocusableListTile(
                          leading: const AppIcon(Symbols.open_in_new_rounded, fill: 1),
                          title: Text(entry.$1),
                          subtitle: Text(entry.$2),
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
                    ],
                  ),

                  const SizedBox(height: 40),

                  SettingsGroup(
                    margin: EdgeInsets.zero,
                    children: [
                      FocusableListTile(
                        leading: const AppIcon(Symbols.description_rounded, fill: 1),
                        title: Text(t.about.openSourceLicenses),
                        subtitle: Text(t.about.viewLicensesDescription),
                        trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                        onTap: () {
                          Navigator.push(context, MaterialPageRoute(builder: (context) => const LicensesScreen()));
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}
