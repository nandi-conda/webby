import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import '../ui.dart';
import 'app_store.dart';
import 'pwa_agent.dart';

/// Decodes any image Flutter can (PNG, JPEG, WebP, GIF, ICO, BMP) and re-encodes it as PNG, at most 512 px.
Future<Uint8List?> iconToPng(Uint8List bytes) async {
  try {
    final probe = await ui.instantiateImageCodec(bytes);
    final first = (await probe.getNextFrame()).image;
    final big = first.width > 512 || first.height > 512;
    var image = first;
    if (big) {
      first.dispose();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 512, targetHeight: 512);
      image = (await codec.getNextFrame()).image;
    }
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return png?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// The URL bar button: "Install app" when the page has a manifest, or the installed app's actions.
class InstallAppButton extends StatelessWidget {
  const InstallAppButton({super.key, required this.agent});

  final PwaAgent agent;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: agent,
      builder: (context, _) {
        final manifest = agent.manifest;
        if (manifest == null) return const SizedBox.shrink();
        final installed = agent.installed;
        return KitIconButton(
          installed == null ? Icons.install_desktop : Icons.open_in_new,
          tooltip: installed == null ? 'Install ${manifest.title}' : 'Open ${installed.name} app',
          color: installed == null ? null : KitTheme.of(context).accent,
          size: 16,
          extent: 26,
          onPressed: () => installed == null ? installApp(context, agent) : manageApp(context, agent.store, installed),
        );
      },
    );
  }
}

/// Asks for the app's name and installs it.
Future<void> installApp(BuildContext context, PwaAgent agent) async {
  final manifest = agent.manifest;
  if (manifest == null) return;
  final name = TextEditingController(text: manifest.title);
  final confirmed = await showWebbyDialog<bool>(
    context,
    (context) => KitDialog(
      title: 'Install app',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledField(
            label: 'Name',
            child: KitTextField(controller: name, autofocus: true, onSubmitted: (_) => Navigator.pop(context, true)),
          ),
          Text(
            '${manifest.startUrl.host}${manifest.startUrl.path}\n'
            'Opens in its own window and gets a launcher in your app menu.',
            style: KitText.dim(context, small: true),
          ),
        ],
      ),
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.pop(context, false)),
        KitButton.primary('Install', onPressed: () => Navigator.pop(context, true)),
      ],
    ),
  );
  final chosen = name.text;
  name.dispose();
  if (confirmed != true) return;
  try {
    final app = await agent.store.install(manifest, name: chosen, iconToPng: iconToPng);
    if (context.mounted) showKitToast(context, '${app.name} installed');
    await agent.store.launch(app);
  } catch (error) {
    if (context.mounted) showKitToast(context, 'Could not install: $error');
  }
}

/// Open or uninstall an installed app.
Future<void> manageApp(BuildContext context, AppStore store, InstalledApp app) async {
  final choice = await showWebbyDialog<String>(
    context,
    (context) => KitDialog(
      title: app.name,
      content: Text('Installed from ${Uri.parse(app.startUrl).host}.', style: KitText.dim(context)),
      actions: [
        KitButton.danger('Uninstall', onPressed: () => Navigator.pop(context, 'uninstall')),
        KitButton('Cancel', onPressed: () => Navigator.pop(context)),
        KitButton.primary('Open app', onPressed: () => Navigator.pop(context, 'open')),
      ],
    ),
  );
  switch (choice) {
    case 'open':
      await store.launch(app);
    case 'uninstall':
      await store.uninstall(app);
      if (context.mounted) showKitToast(context, '${app.name} uninstalled');
  }
}
