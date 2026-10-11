import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import '../passwords/password_manager.dart';
import '../passwords/sync/sync_page.dart';
import '../ui.dart';
import 'device_tabs.dart';

/// "Tabs from other devices": the tabs each synced device has open, grouped by device.
///
/// Pops with the URLs to open in new tabs.
class DeviceTabsPage extends StatefulWidget {
  const DeviceTabsPage({super.key, this.tabs, this.manager});

  final DeviceTabs? tabs;
  final PasswordManager? manager;

  @override
  State<DeviceTabsPage> createState() => _DeviceTabsPageState();
}

/// How long ago [seconds] (since the epoch) was, in a few words.
String seenAgo(int seconds, {DateTime? now}) {
  final ago = (now ?? DateTime.now()).difference(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
  if (ago.inMinutes < 1) return 'just now';
  if (ago.inHours < 1) return '${ago.inMinutes} min ago';
  if (ago.inDays < 1) return '${ago.inHours} h ago';
  return ago.inDays == 1 ? 'yesterday' : '${ago.inDays} days ago';
}

class _DeviceTabsPageState extends State<DeviceTabsPage> {
  DeviceTabs get _tabs => widget.tabs ?? DeviceTabs.instance;
  PasswordManager get _manager => widget.manager ?? PasswordManager.instance;

  @override
  void initState() {
    super.initState();
    // Fetch the latest from the other devices.
    final sync = _manager.sync;
    if (sync != null && sync.enabled && !sync.syncing) sync.syncNow();
  }

  Future<void> _rename() async {
    final field = TextEditingController(text: _tabs.name);
    final name = await showWebbyDialog<String>(
      context,
      (context) => KitDialog(
        title: 'Name this device',
        content: LabeledField(
          label: 'Other devices list its tabs under this name',
          child: KitTextField(controller: field, autofocus: true, onSubmitted: (value) => Navigator.pop(context, value)),
        ),
        actions: [
          KitButton('Cancel', onPressed: () => Navigator.pop(context)),
          KitButton.primary('Save', onPressed: () => Navigator.pop(context, field.text)),
        ],
      ),
    );
    field.dispose();
    if (name != null) _tabs.name = name;
  }

  @override
  Widget build(BuildContext context) {
    final sync = _manager.sync;
    return ListenableBuilder(
      listenable: Listenable.merge([_tabs, _manager, ?sync]),
      builder: (context, _) {
        final syncing = sync?.syncing ?? false;
        return KitPage(
          title: 'Tabs from other devices',
          actions: [
            if (sync != null && sync.enabled)
              KitButton(syncing ? 'Syncing…' : 'Refresh', icon: Icons.sync, onPressed: syncing ? null : sync.syncNow),
          ],
          body: sync == null || !sync.enabled ? _syncOff(context) : _list(context),
        );
      },
    );
  }

  Widget _syncOff(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('See the tabs open on your other devices', style: KitText.heading(context)),
        const SizedBox(height: 8),
        Text(
          'Tabs travel with your passwords and bookmarks, encrypted with your sync code. Turn on sync here and on '
          'your other devices to see their tabs.',
          style: KitText.dim(context),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: KitButton.primary('Set up sync', icon: Icons.sync, onPressed: () {
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SyncPage(manager: widget.manager)));
          }),
        ),
      ],
    );
  }

  Widget _list(BuildContext context) {
    final c = KitTheme.of(context);
    final devices = _tabs.devices;
    final error = _manager.sync?.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) KitBanner(message: 'Sync isn\'t working: $error', danger: true),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No other devices have shared their tabs yet. They show up here once webby on another device '
                    'is syncing with the same sync code.',
                    style: KitText.dim(context),
                  ),
                ),
              for (final device in devices) ...[
                _DeviceHeader(
                  device: device,
                  onOpenAll: device.tabs.length > 1
                      ? () => Navigator.pop(context, [for (final tab in device.tabs) tab.url])
                      : null,
                ),
                if (device.tabs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text('No open tabs', style: KitText.dim(context, small: true)),
                  ),
                for (final tab in device.tabs)
                  _TabRow(tab: tab, onOpen: () => Navigator.pop(context, [tab.url])),
                const SizedBox(height: 12),
              ],
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Container(height: 1, color: c.border)),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('This device: ${_tabs.name}', style: KitText.body(context)),
                          const SizedBox(height: 2),
                          Text(
                            _tabs.share
                                ? 'Your other devices see the ${_tabs.tabs.length} tab${_tabs.tabs.length == 1 ? '' : 's'} open here.'
                                : 'Your other devices don\'t see the tabs open here.',
                            style: KitText.dim(context, small: true),
                          ),
                        ],
                      ),
                    ),
                    KitButton('Rename', onPressed: _rename),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: KitCheckbox(
                  value: _tabs.share,
                  label: 'Share this device\'s tabs',
                  onChanged: (value) => _tabs.share = value,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DeviceHeader extends StatelessWidget {
  const _DeviceHeader({required this.device, this.onOpenAll});

  final RemoteDevice device;
  final VoidCallback? onOpenAll;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final icon = device.platform == 'android' || device.platform == 'ios' ? Icons.smartphone : Icons.computer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c.textDim),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: device.name, style: KitText.heading(context).copyWith(fontSize: 14)),
                TextSpan(text: '  ${seenAgo(device.seenAt)}', style: KitText.dim(context, small: true)),
              ]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onOpenAll != null) KitButton('Open all', onPressed: onOpenAll),
        ],
      ),
    );
  }
}

class _TabRow extends StatelessWidget {
  const _TabRow({required this.tab, required this.onOpen});

  final DeviceTab tab;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(tab.url);
    final host = uri == null || uri.host.isEmpty ? tab.url : uri.host;
    return KitTooltip(
      message: tab.url,
      child: KitListRow(
        onTap: onOpen,
        height: null,
        padding: const EdgeInsets.fromLTRB(48, 6, 24, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tab.title.isEmpty ? host : tab.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: KitText.body(context)),
              Text(host, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.dim(context, small: true)),
            ],
          ),
      ),
    );
  }
}
