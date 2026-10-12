import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import 'site_permissions.dart';
import 'ui.dart';
import 'web_view.dart';

/// How the prompt and the panel name a site: its host without "www.", with the scheme only when it isn't https.
String siteName(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || uri.host.isEmpty) return origin;
  var host = uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
  if (uri.hasPort) host = '$host:${uri.port}';
  return uri.scheme == 'https' ? host : '${uri.scheme}://$host';
}

/// Chrome's permission prompt: a card under the address bar asking whether the site may use a feature, shown while
/// [controller]'s page has a request waiting. Put it in a [Stack] over the page.
class PermissionBubble extends StatelessWidget {
  const PermissionBubble({super.key, required this.controller});

  final WebbyController controller;

  @override
  Widget build(BuildContext context) {
    final request = controller.permissionRequest;
    final kind = request == null ? null : SitePermissionKind.named(request.permission);
    if (request == null || kind == null) return const SizedBox.shrink();
    final c = KitTheme.of(context);

    Widget choice(String label, {required bool allow, required bool remember}) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: SizedBox(
            width: double.infinity,
            child: KitButton(label, onPressed: () => controller.answerPermission(allow: allow, remember: remember)),
          ),
        );

    return Positioned(
      top: 4,
      left: 8,
      child: Container(
        width: 320,
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 12),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(kitRadius),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${siteName(request.origin)} wants to',
                      style: KitText.heading(context), overflow: TextOverflow.ellipsis),
                ),
                // Closing it is a "no" for now, asked again next time.
                KitIconButton.compact(Icons.close,
                    tooltip: 'Close', onPressed: () => controller.answerPermission(allow: false, remember: false)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(kind.icon, size: 18, color: c.textDim),
                const SizedBox(width: 8),
                Text(kind.request),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                children: [
                  choice('Allow while visiting the site', allow: true, remember: true),
                  choice('Allow this time', allow: true, remember: false),
                  choice('Never allow', allow: false, remember: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The site settings panel behind the address bar's tune icon: the connection, and what the page's site may use.
Future<void> showSiteSettings(BuildContext context, WebbyController controller) async {
  final url = controller.url;
  final origin = originOf(url);
  final store = SitePermissionStore.instance;
  var changed = false;

  await showWebbyDialog<void>(context, (dialogContext) {
    return StatefulBuilder(builder: (context, setState) {
      final c = KitTheme.of(context);
      final secure = origin != null && origin.startsWith('https:');
      return ListenableBuilder(
        listenable: store,
        builder: (context, _) => KitDialog(
          title: origin == null ? 'Site settings' : siteName(origin),
          width: 380,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (origin == null)
                Text('This page has no site settings.', style: KitText.dim(context))
              else ...[
                Row(
                  children: [
                    Icon(secure ? Icons.lock_outline : Icons.lock_open, size: 16, color: c.textDim),
                    const SizedBox(width: 8),
                    Text(secure ? 'Connection is secure' : 'Connection is not secure'),
                  ],
                ),
                const SizedBox(height: 12),
                const KitDivider(),
                const SizedBox(height: 12),
                Text('Permissions', style: KitText.dim(context, small: true)),
                const SizedBox(height: 6),
                for (final kind in SitePermissionKind.all)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(kind.icon, size: 18, color: c.textDim),
                        const SizedBox(width: 10),
                        Expanded(child: Text(kind.label)),
                        KitSelect<PermissionSetting>(
                          value: store.get(origin, kind.name),
                          options: const [
                            (PermissionSetting.ask, 'Ask (default)'),
                            (PermissionSetting.allow, 'Allow'),
                            (PermissionSetting.block, 'Block'),
                          ],
                          onChanged: (setting) {
                            store.set(origin, kind.name, setting);
                            if (setting != PermissionSetting.allow) controller.forgetPermissions(origin);
                            setState(() => changed = true);
                          },
                        ),
                      ],
                    ),
                  ),
                if (!secure) ...[
                  const SizedBox(height: 6),
                  Text('Pages that aren\'t secure can\'t use these.', style: KitText.dim(context, small: true)),
                ],
                if (changed) ...[
                  const SizedBox(height: 10),
                  Text('Reload the page to apply the new settings.', style: KitText.dim(context, small: true)),
                ],
              ],
            ],
          ),
          actions: [
            if (origin != null && store.hasSettings(origin))
              KitButton('Reset permissions', onPressed: () {
                store.reset(origin);
                controller.forgetPermissions(origin);
                setState(() => changed = true);
              }),
            if (changed)
              KitButton('Reload', onPressed: () {
                controller.reload();
                Navigator.of(dialogContext).pop();
              }),
            KitButton.primary('Done', autofocus: true, onPressed: () => Navigator.of(dialogContext).pop()),
          ],
        ),
      );
    });
  });
}
