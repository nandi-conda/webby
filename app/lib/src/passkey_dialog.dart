import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import 'ui.dart';
import 'web_view.dart';

/// Asks the user to approve a page's passkey request (see `webby_view_webauthn_prompt` in webby_ffi.h) and sends the
/// answer back to the view. Closing the dialog any other way cancels the request.
Future<void> showPasskeyDialog(BuildContext context, WebbyController controller, Map<String, Object?> prompt) async {
  var answered = false;
  void answer(BuildContext dialogContext, {required bool accepted, int accountIndex = -1}) {
    if (answered) return;
    answered = true;
    controller.respondToWebAuthn(accepted: accepted, accountIndex: accountIndex);
    Navigator.of(dialogContext).pop();
  }

  final rpId = prompt['rpId'] as String? ?? '';
  final isCreate = prompt['type'] == 'create';

  await showWebbyDialog<void>(context, (dialogContext) {
    final bold = KitText.heading(dialogContext);
    if (isCreate) {
      final userName = prompt['userName'] as String? ?? '';
      final displayName = prompt['userDisplayName'] as String? ?? '';
      final account = displayName.isNotEmpty && displayName != userName ? '$displayName ($userName)' : userName;
      if (prompt['alreadyRegistered'] == true) {
        return KitDialog(
          title: 'Passkey already saved',
          content: Text('This browser already has a passkey for your account on $rpId.'),
          actions: [
            KitButton('Cancel', onPressed: () => answer(dialogContext, accepted: false)),
            KitButton.primary('OK', autofocus: true, onPressed: () => answer(dialogContext, accepted: true)),
          ],
        );
      }
      return KitDialog(
        title: 'Create a passkey?',
        content: Text.rich(TextSpan(children: [
          const TextSpan(text: 'Save a passkey for '),
          TextSpan(text: account.isEmpty ? 'your account' : account, style: bold),
          const TextSpan(text: ' on '),
          TextSpan(text: rpId, style: bold),
          const TextSpan(text: '. It stays in this browser and signs you in without a password.'),
        ])),
        actions: [
          KitButton('Cancel', onPressed: () => answer(dialogContext, accepted: false)),
          KitButton.primary('Create', autofocus: true, onPressed: () => answer(dialogContext, accepted: true)),
        ],
      );
    }

    final accounts = (prompt['accounts'] as List<Object?>? ?? const []).cast<Map<String, Object?>>();
    if (accounts.isEmpty) {
      return KitDialog(
        title: 'No passkeys',
        content: Text('This browser has no passkeys for $rpId.'),
        actions: [
          KitButton.primary('OK', autofocus: true, onPressed: () => answer(dialogContext, accepted: false)),
        ],
      );
    }
    return KitDialog(
      title: 'Sign in to $rpId',
      width: 360,
      content: KitPanel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, account) in accounts.indexed)
              KitTile(
                icon: Icons.account_circle,
                title: (account['userDisplayName'] as String?)?.isNotEmpty == true
                    ? account['userDisplayName'] as String
                    : account['userName'] as String? ?? '',
                subtitle: Text(account['userName'] as String? ?? ''),
                onTap: () => answer(dialogContext, accepted: true, accountIndex: index),
              ),
          ],
        ),
      ),
      actions: [
        KitButton('Cancel', onPressed: () => answer(dialogContext, accepted: false)),
      ],
    );
  });

  // Dismissed with Escape or a click outside.
  if (!answered) controller.respondToWebAuthn(accepted: false);
}
