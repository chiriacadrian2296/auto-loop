import 'dart:io';

import 'package:flutter/material.dart';

import '../engine/accounts.dart';
import '../engine/cli_locator.dart';
import '../engine/settings.dart';
import 'agent_badge.dart';
import 'app_theme.dart';
import '../l10n.dart';

/// Profiles, CLI executables and the account each CLI is signed in with.
Future<void> showAccountsDialog(
  BuildContext context, {
  required LoopSettings settings,
  required bool locked,
  required VoidCallback onChanged,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.35),
  builder: (_) => _AccountsDialog(settings: settings, locked: locked, onChanged: onChanged),
);

String planLabel(String? plan) => switch (plan?.toLowerCase()) {
  null || '' => '',
  'pro' => 'Pro',
  'plus' => 'Plus',
  'max' => 'Max',
  'team' => 'Team',
  'enterprise' => 'Enterprise',
  'free' => 'Free',
  final other => other[0].toUpperCase() + other.substring(1),
};

class _AccountsDialog extends StatefulWidget {
  const _AccountsDialog({required this.settings, required this.locked, required this.onChanged});
  final LoopSettings settings;
  final bool locked;
  final VoidCallback onChanged;

  @override
  State<_AccountsDialog> createState() => _AccountsDialogState();
}

class _AccountsDialogState extends State<_AccountsDialog> {
  LoopSettings get s => widget.settings;
  final _status = <AgentKind, AccountStatus?>{};
  final _version = <AgentKind, String?>{};
  final _busy = <AgentKind, String?>{};

  @override
  void initState() {
    super.initState();
    _refreshAll();
  }

  String _path(AgentKind k) => k == AgentKind.codex ? s.codexPath : s.claudePath;
  void _setPath(AgentKind k, String v) => k == AgentKind.codex ? s.codexPath = v : s.claudePath = v;

  Future<void> _refresh(AgentKind k) async {
    setState(() => _status[k] = null);
    final exe = _path(k);
    final results = await Future.wait([cliVersion(exe), accountStatus(k, exe, s.profileId)]);
    if (!mounted) return;
    setState(() {
      _version[k] = results[0] as String?;
      _status[k] = results[1] as AccountStatus;
    });
  }

  void _refreshAll() {
    for (final k in AgentKind.values) {
      _refresh(k);
    }
  }

  Future<void> _detect(AgentKind k) async {
    final found = await locateCli(k);
    if (found != null) {
      _setPath(k, found);
      widget.onChanged();
    }
    await _refresh(k);
  }

  Future<bool> _confirmSystemLogout(AgentKind k) async {
    if (!s.profile.isDefault) return true;
    final app = k == AgentKind.codex
        ? tr('l\'app Codex e la sua CLI', 'the Codex app and its CLI')
        : tr('Claude (terminale, VS Code e app)', 'Claude (terminal, VS Code and app)');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Account di questo computer', 'This computer\'s account')),
        content: Text(
          tr(
            'Questo è lo stesso accesso usato da $app. Uscendo verrai scollegato anche lì.\n\n'
                'Per usare un altro account senza toccare il tuo, crea un set di account separato.',
            'This is the same sign-in used by $app. Signing out signs you out there too.\n\nTo use another account without touching yours, create a separate account set.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annulla', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Continua', 'Continue'))),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _login(AgentKind k) async {
    setState(
      () => _busy[k] = tr(
        'Completa l\'accesso nella finestra che si è aperta…',
        'Finish signing in in the window that opened…',
      ),
    );
    await startLogin(k, _path(k), s.profileId);
    if (!mounted) return;
    setState(() => _busy[k] = null);
    await _refresh(k);
  }

  Future<void> _logout(AgentKind k, {bool thenLogin = false}) async {
    if (!await _confirmSystemLogout(k)) return;
    setState(() => _busy[k] = tr('Uscita in corso…', 'Signing out…'));
    final error = await logout(k, _path(k), s.profileId);
    if (!mounted) return;
    setState(() => _busy[k] = null);
    if (error != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(tr('Uscita non riuscita: $error', 'Sign-out failed: $error'))));
    }
    if (thenLogin && error == null) {
      await _login(k);
    } else {
      await _refresh(k);
    }
  }

  Future<String?> _askName(String title, [String initial = '']) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 340,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: tr('es. Lavoro, Personale, Mario', 'e.g. Work, Personal, Mario')),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Annulla', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(tr('Salva', 'Save'))),
        ],
      ),
    );
  }

  Future<void> _newProfile() async {
    final name = (await _askName(tr('Nuovo set di account', 'New account set')))?.trim();
    if (name == null || name.isEmpty) return;
    final profile = AccountProfile(id: newProfileId(), name: name);
    setState(() {
      s.profiles.add(profile);
      s.profileId = profile.id;
    });
    widget.onChanged();
    _refreshAll();
  }

  Future<void> _rename(AccountProfile profile) async {
    final name = (await _askName(tr('Rinomina set di account', 'Rename account set'), profile.name))?.trim();
    if (name == null || name.isEmpty) return;
    setState(() {
      final i = s.profiles.indexWhere((x) => x.id == profile.id);
      if (i >= 0) s.profiles[i] = AccountProfile(id: profile.id, name: name);
    });
    widget.onChanged();
  }

  Future<void> _delete(AccountProfile profile) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Eliminare «${profile.name}»?', 'Delete «${profile.name}»?')),
        content: Text(
          tr(
            'Gli accessi a Codex e Claude salvati in questo set verranno cancellati '
                'da questo computer. Non si può annullare.',
            'The Codex and Claude sign-ins saved in this set will be deleted from this computer. This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annulla', 'Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.colors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Elimina', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      deleteProfileData(profile.id);
    } catch (_) {}
    setState(() {
      s.profiles.removeWhere((x) => x.id == profile.id);
      if (s.profileId == profile.id) s.profileId = AccountProfile.defaultId;
    });
    widget.onChanged();
    _refreshAll();
  }

  void _select(AccountProfile profile) {
    if (profile.id == s.profileId) return;
    setState(() => s.profileId = profile.id);
    widget.onChanged();
    _refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 14, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('Account e CLI', 'Accounts and CLIs'),
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr(
                            'Con quali account lavorano gli agenti, e dove si trovano le loro CLI.',
                            'Which accounts the agents work with, and where their CLIs are.',
                          ),
                          style: TextStyle(fontSize: 12.5, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    iconSize: 18,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (widget.locked)
              Container(
                margin: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  tr(
                    'Il loop è in esecuzione: fermalo per cambiare account.',
                    'The loop is running: stop it to change account.',
                  ),
                  style: TextStyle(color: c.warning, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            Flexible(
              child: AbsorbPointer(
                absorbing: widget.locked,
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  children: [
                    SectionLabel(
                      s.profile.isDefault
                          ? tr('Account in uso', 'Account in use')
                          : tr('Account in uso · set «${s.profile.name}»', 'Account in use · set «${s.profile.name}»'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final k in AgentKind.values) ...[
                          if (k != AgentKind.values.first) const SizedBox(width: 14),
                          Expanded(
                            child: _CliCard(
                              kind: k,
                              path: _path(k),
                              version: _version[k],
                              status: _status[k],
                              busy: _busy[k],
                              onPathChanged: (v) {
                                _setPath(k, v.trim());
                                widget.onChanged();
                              },
                              onPathSubmitted: () => _refresh(k),
                              onDetect: () => _detect(k),
                              onLogin: () => _login(k),
                              onSwitch: () => _logout(k, thenLogin: true),
                              onLogout: () => _logout(k),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 24),
                    SectionLabel(
                      tr('Altri account', 'Other accounts'),
                      trailing: s.profiles.isEmpty
                          ? null
                          : TextButton.icon(
                              onPressed: _newProfile,
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: Text(tr('Nuovo set', 'New set')),
                            ),
                    ),
                    const SizedBox(height: 8),
                    if (s.profiles.isEmpty)
                      _ProfilesIntro(onCreate: _newProfile)
                    else ...[
                      Text(
                        tr(
                          'Ogni set ha accessi propri a Codex e Claude. Scegli quale usare:',
                          'Every set has its own Codex and Claude sign-ins. Choose which one to use:',
                        ),
                        style: TextStyle(fontSize: 12.5, color: c.muted),
                      ),
                      const SizedBox(height: 6),
                      for (final profile in s.allProfiles)
                        _ProfileRow(
                          profile: profile,
                          selected: profile.id == s.profileId,
                          onTap: () => _select(profile),
                          onRename: profile.isDefault ? null : () => _rename(profile),
                          onDelete: profile.isDefault ? null : () => _delete(profile),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while only the computer's own accounts exist: explains what a
/// separate set is for, instead of a list with a single choice.
class _ProfilesIntro extends StatelessWidget {
  const _ProfilesIntro({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(14)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.group_add_outlined, size: 22, color: c.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    'AutoLoop usa gli account con cui hai già fatto l\'accesso su questo computer.',
                    'AutoLoop uses the accounts you are already signed in with on this computer.',
                  ),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
                ),
                const SizedBox(height: 4),
                Text(
                  tr(
                    'Per farlo lavorare con altri account, tuoi o di un\'altra persona, crea un set di account '
                        'separato: avrà accessi propri e non toccherà quelli che usi normalmente.',
                    'To make it work with other accounts, yours or someone else\'s, create a separate account set: it will have its own sign-ins and will not touch the ones you normally use.',
                  ),
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: c.muted),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(tr('Crea un set di account', 'Create an account set')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.profile, required this.selected, required this.onTap, this.onRename, this.onDelete});
  final AccountProfile profile;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onRename, onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? c.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          hoverColor: c.field,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected ? c.primary : c.muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: selected ? c.primary : c.text,
                        ),
                      ),
                      Text(
                        profile.isDefault
                            ? tr(
                                'Gli account con cui hai già fatto l\'accesso su questo computer.',
                                'The accounts you are already signed in with on this computer.',
                              )
                            : tr('Accessi propri, usati solo da AutoLoop.', 'Its own sign-ins, used only by AutoLoop.'),
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                    ],
                  ),
                ),
                if (onRename != null)
                  IconButton(
                    tooltip: tr('Rinomina', 'Rename'),
                    onPressed: onRename,
                    iconSize: 18,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                if (onDelete != null)
                  IconButton(
                    tooltip: tr('Elimina', 'Delete'),
                    onPressed: onDelete,
                    iconSize: 18,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CliCard extends StatelessWidget {
  const _CliCard({
    required this.kind,
    required this.path,
    required this.version,
    required this.status,
    required this.busy,
    required this.onPathChanged,
    required this.onPathSubmitted,
    required this.onDetect,
    required this.onLogin,
    required this.onSwitch,
    required this.onLogout,
  });

  final AgentKind kind;
  final String path;
  final String? version;
  final AccountStatus? status;
  final String? busy;
  final ValueChanged<String> onPathChanged;
  final VoidCallback onPathSubmitted, onDetect, onLogin, onSwitch, onLogout;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final found = path.isNotEmpty && File(path).existsSync();
    final st = status;
    final loading = st == null || busy != null;

    final (Color dot, String headline, String detail) = !found
        ? (
            c.danger,
            tr('CLI non trovata', 'CLI not found'),
            tr(
              'Indica il percorso o premi la lente per cercarla.',
              'Enter the path or press the magnifier to look for it.',
            ),
          )
        : st == null
        ? (c.muted, tr('Controllo in corso…', 'Checking…'), '')
        : st.loggedIn
        ? (
            c.success,
            st.email ?? tr('Connesso', 'Signed in'),
            [
              if (planLabel(st.plan).isNotEmpty) tr('Piano ${planLabel(st.plan)}', '${planLabel(st.plan)} plan'),
              if (st.method != null) 'via ${st.method}',
            ].join(' · '),
          )
        : (
            c.warning,
            tr('Non connesso', 'Not signed in'),
            tr(
              'Accedi per far lavorare ${kind.label} con questi account.',
              'Sign in to make ${kind.label} work with these accounts.',
            ),
          );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AgentBadge(kind: kind, size: 26),
              const SizedBox(width: 10),
              Text(
                kind.label,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.text),
              ),
              const SizedBox(width: 8),
              if (version != null)
                Flexible(
                  child: Text(
                    'v${RegExp(r'\d+\.\d+\.\d+').firstMatch(version!)?.group(0) ?? version!}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: c.muted),
                  ),
                )
              else
                const Spacer(),
              if (version != null) const Spacer(),
              IconButton(
                tooltip: tr('Cerca la CLI', 'Look for the CLI'),
                onPressed: onDetect,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.manage_search_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: ValueKey('path-$kind-$path'),
            initialValue: path,
            onChanged: onPathChanged,
            onFieldSubmitted: (_) => onPathSubmitted(),
            style: const TextStyle(fontSize: 11.5, fontFamily: mono, fontFamilyFallback: monoFallback),
            decoration: InputDecoration(
              fillColor: c.surface,
              hintText: tr('Percorso dell\'eseguibile', 'Path of the executable'),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c.surface),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: dot.withValues(alpha: 0.12), shape: BoxShape.circle),
                  child: loading
                      ? Padding(
                          padding: const EdgeInsets.all(10),
                          child: CircularProgressIndicator(strokeWidth: 2, color: c.primary),
                        )
                      : Icon(st.loggedIn ? Icons.person_rounded : Icons.person_off_outlined, size: 19, color: dot),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        busy ?? headline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text),
                      ),
                      if (busy == null && detail.isNotEmpty)
                        Text(detail, style: TextStyle(fontSize: 11.5, color: c.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (found && st != null && !st.loggedIn)
                FilledButton.icon(
                  onPressed: busy == null ? onLogin : null,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                  icon: const Icon(Icons.login_rounded, size: 17),
                  label: Text(tr('Accedi', 'Sign in')),
                ),
              if (found && st != null && st.loggedIn) ...[
                OutlinedButton.icon(
                  onPressed: busy == null ? onSwitch : null,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                  label: Text(tr('Cambia account', 'Switch account')),
                ),
                TextButton.icon(
                  onPressed: busy == null ? onLogout : null,
                  style: TextButton.styleFrom(foregroundColor: c.danger),
                  icon: const Icon(Icons.logout_rounded, size: 17),
                  label: Text(tr('Esci', 'Sign out')),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
