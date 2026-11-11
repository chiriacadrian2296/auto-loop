import 'dart:io';

import 'package:flutter/material.dart';

import '../engine/accounts.dart';
import '../engine/cli_locator.dart';
import '../engine/settings.dart';
import 'agent_badge.dart';
import 'app_theme.dart';

/// Profiles, CLI executables and the account each CLI is signed in with.
Future<void> showAccountsDialog(
  BuildContext context, {
  required LoopSettings settings,
  required bool locked,
  required VoidCallback onChanged,
}) =>
    showDialog<void>(
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
    final app = k == AgentKind.codex ? 'l\'app Codex e la CLI' : 'Claude Code (terminale, VS Code e app)';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Account di sistema'),
        content: Text(
          'Questo profilo usa lo stesso accesso di $app. Uscendo verrai scollegato anche lì.\n\n'
          'Per usare un altro account senza toccare il tuo, crea un nuovo profilo.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continua')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _login(AgentKind k) async {
    setState(() => _busy[k] = 'Completa l\'accesso nella finestra che si è aperta…');
    await startLogin(k, _path(k), s.profileId);
    if (!mounted) return;
    setState(() => _busy[k] = null);
    await _refresh(k);
  }

  Future<void> _logout(AgentKind k, {bool thenLogin = false}) async {
    if (!await _confirmSystemLogout(k)) return;
    setState(() => _busy[k] = 'Uscita in corso…');
    final error = await logout(k, _path(k), s.profileId);
    if (!mounted) return;
    setState(() => _busy[k] = null);
    if (error != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Uscita non riuscita: $error')));
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
            decoration: const InputDecoration(hintText: 'es. Lavoro, Personale, Mario'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Salva')),
        ],
      ),
    );
  }

  Future<void> _newProfile() async {
    final name = (await _askName('Nuovo profilo'))?.trim();
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
    final name = (await _askName('Rinomina profilo', profile.name))?.trim();
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
        title: Text('Eliminare «${profile.name}»?'),
        content: const Text('Gli accessi a Codex e Claude salvati in questo profilo verranno cancellati '
            'da questo computer. Non si può annullare.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.colors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Elimina'),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: c.border)),
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
                        Text('Account e CLI',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text)),
                        const SizedBox(height: 2),
                        Text('Con quali account AutoLoop fa lavorare gli agenti.',
                            style: TextStyle(fontSize: 12.5, color: c.muted)),
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
                child: Text('Il loop è in esecuzione: fermalo per cambiare profilo o account.',
                    style: TextStyle(color: c.warning, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            Flexible(
              child: AbsorbPointer(
                absorbing: widget.locked,
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  children: [
                    SectionLabel('Profilo',
                        trailing: TextButton.icon(
                          onPressed: _newProfile,
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Nuovo profilo'),
                        )),
                    const SizedBox(height: 6),
                    for (final profile in s.allProfiles)
                      _ProfileRow(
                        profile: profile,
                        selected: profile.id == s.profileId,
                        onTap: () => _select(profile),
                        onRename: profile.isDefault ? null : () => _rename(profile),
                        onDelete: profile.isDefault ? null : () => _delete(profile),
                      ),
                    const SizedBox(height: 20),
                    SectionLabel('Accessi del profilo «${s.profile.name}»'),
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
                Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                    size: 20, color: selected ? c.primary : c.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(profile.name,
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600, color: selected ? c.primary : c.text)),
                      Text(
                        profile.isDefault
                            ? 'Gli stessi accessi di Codex e Claude Code installati su questo computer.'
                            : 'Accessi separati, salvati solo per AutoLoop.',
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                    ],
                  ),
                ),
                if (onRename != null)
                  IconButton(
                    tooltip: 'Rinomina',
                    onPressed: onRename,
                    iconSize: 18,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                if (onDelete != null)
                  IconButton(
                    tooltip: 'Elimina',
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
        ? (c.danger, 'CLI non trovata', 'Indica il percorso o premi la lente per cercarla.')
        : st == null
            ? (c.muted, 'Controllo in corso…', '')
            : st.loggedIn
                ? (
                    c.success,
                    st.email ?? 'Connesso',
                    [
                      if (planLabel(st.plan).isNotEmpty) 'Piano ${planLabel(st.plan)}',
                      if (st.method != null) 'via ${st.method}',
                    ].join(' · '),
                  )
                : (c.warning, 'Non connesso', 'Accedi per far lavorare ${kind.label} con questo profilo.');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.field,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AgentBadge(kind: kind, size: 26),
              const SizedBox(width: 10),
              Text(kind.label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.text)),
              const SizedBox(width: 8),
              if (version != null)
                Flexible(
                  child: Text(version!,
                      overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: c.muted)),
                )
              else
                const Spacer(),
              if (version != null) const Spacer(),
              IconButton(
                tooltip: 'Cerca la CLI',
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
              hintText: 'Percorso dell\'eseguibile',
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
                      : Icon(
                          st.loggedIn ? Icons.person_rounded : Icons.person_off_outlined,
                          size: 19,
                          color: dot,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(busy ?? headline,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text)),
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
                  label: const Text('Accedi'),
                ),
              if (found && st != null && st.loggedIn) ...[
                OutlinedButton.icon(
                  onPressed: busy == null ? onSwitch : null,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                  label: const Text('Cambia account'),
                ),
                TextButton.icon(
                  onPressed: busy == null ? onLogout : null,
                  style: TextButton.styleFrom(foregroundColor: c.danger),
                  icon: const Icon(Icons.logout_rounded, size: 17),
                  label: const Text('Esci'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
