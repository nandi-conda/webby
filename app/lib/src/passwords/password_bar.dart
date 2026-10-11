import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import 'password_manager.dart';

/// The strip above the page that offers to save or fill a password.
class PasswordBar extends StatelessWidget {
  const PasswordBar({super.key, required this.agent});

  final PasswordAgent agent;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: agent,
      builder: (context, _) {
        final offer = agent.offer;
        if (offer == null) return const SizedBox.shrink();
        final c = KitTheme.of(context);
        final host = Uri.parse(offer.origin).host;
        final bold = KitText.heading(context);

        final (Widget message, List<Widget> actions) = switch (offer) {
          SaveOffer() => (
              Text.rich(TextSpan(children: [
                TextSpan(text: offer.existing != null ? 'Update the saved password for ' : 'Save the password for '),
                TextSpan(text: offer.username.isEmpty ? 'this account' : offer.username, style: bold),
                const TextSpan(text: ' on '),
                TextSpan(text: host, style: bold),
                const TextSpan(text: '?'),
              ])),
              [
                if (offer.existing == null)
                  KitButton.ghost('Never for this site', onPressed: () => agent.neverSave(offer)),
                KitButton('Not now', onPressed: agent.dismiss),
                KitButton.primary(offer.existing != null ? 'Update' : 'Save', onPressed: () => agent.save(offer)),
              ],
            ),
          FillOffer() => (
              Text.rich(TextSpan(children: [
                const TextSpan(text: 'Fill a saved password for '),
                TextSpan(text: host, style: bold),
              ])),
              [
                for (final account in offer.accounts.take(4))
                  KitButton(
                    account.username.isEmpty ? '(no username)' : account.username,
                    icon: Icons.account_circle,
                    onPressed: () => agent.fill(account),
                  ),
                KitIconButton(Icons.close, tooltip: 'Close', onPressed: agent.dismiss),
              ],
            ),
        };

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.border), left: BorderSide(color: c.accent, width: 3)),
          ),
          child: Row(
            children: [
              Icon(Icons.key, size: 18, color: c.accent),
              const SizedBox(width: 12),
              Expanded(child: message),
              Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
            ],
          ),
        );
      },
    );
  }
}
