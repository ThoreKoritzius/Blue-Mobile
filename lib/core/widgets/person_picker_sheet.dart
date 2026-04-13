import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/person_model.dart';
import '../../data/repositories/person_repository.dart';

class PersonPickerSheet extends StatefulWidget {
  const PersonPickerSheet({
    super.key,
    required this.repository,
    this.selectedNames = const [],
    this.allowCreate = false,
    this.initialQuery = '',
    this.title = 'Add person',
  });

  final PersonRepository repository;
  final List<String> selectedNames;
  final bool allowCreate;
  final String initialQuery;
  final String title;

  static Future<PersonModel?> show(
    BuildContext context, {
    required PersonRepository repository,
    List<String> selectedNames = const [],
    bool allowCreate = false,
    String initialQuery = '',
    String title = 'Add person',
  }) {
    return showModalBottomSheet<PersonModel>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PersonPickerSheet(
        repository: repository,
        selectedNames: selectedNames,
        allowCreate: allowCreate,
        initialQuery: initialQuery,
        title: title,
      ),
    );
  }

  @override
  State<PersonPickerSheet> createState() => _PersonPickerSheetState();
}

class _PersonPickerSheetState extends State<PersonPickerSheet> {
  late final TextEditingController _searchController;
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _relationController;
  Timer? _debounce;
  bool _loading = false;
  bool _showCreate = false;
  bool _creating = false;
  List<PersonModel> _popular = const [];
  List<PersonModel> _results = const [];

  bool _isAlreadySelected(PersonModel person) {
    final normalized = person.displayName.trim().toLowerCase();
    return widget.selectedNames.any(
      (name) => name.trim().toLowerCase() == normalized,
    );
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery);
    _firstNameController = TextEditingController();
    _lastNameController = TextEditingController();
    _relationController = TextEditingController();
    _loadPopular();
    if (widget.initialQuery.trim().length >= 2) {
      _onChanged(widget.initialQuery);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _relationController.dispose();
    super.dispose();
  }

  Future<void> _loadPopular() async {
    setState(() => _loading = true);
    try {
      final people = await widget.repository.popular(first: 12);
      if (!mounted) return;
      setState(() {
        _popular = people;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _loading = false;
        _results = _popular;
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 220), () async {
      if (!mounted) return;
      setState(() => _loading = true);
      try {
        final results = await widget.repository.search(query);
        if (!mounted) return;
        setState(() {
          _results = results;
          _loading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _results = const [];
          _loading = false;
        });
      }
    });
  }

  Future<void> _createPerson() async {
    final firstName = _firstNameController.text.trim();
    if (firstName.isEmpty) return;
    setState(() => _creating = true);
    try {
      final created = await widget.repository.create(
        PersonModel(
          id: 0,
          firstName: firstName,
          lastName: _lastNameController.text.trim(),
          birthDate: '',
          deathDate: '',
          relation: _relationController.text.trim(),
          profession: '',
          studyProgram: '',
          languages: '',
          email: '',
          phone: '',
          address: '',
          notes: '',
          biography: '',
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final query = _searchController.text.trim();
    final visibleResults = query.length < 2 ? _popular : _results;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        12 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.38),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 32,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _showCreate ? 'Create new person' : widget.title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (widget.allowCreate)
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _showCreate = !_showCreate;
                          });
                        },
                        child: Text(_showCreate ? 'Back' : 'New'),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                if (_showCreate)
                  _buildCreateForm(context)
                else ...[
                  TextField(
                    controller: _searchController,
                    autofocus: true,
                    onChanged: _onChanged,
                    decoration: const InputDecoration(
                      labelText: 'Search people',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : visibleResults.isEmpty
                        ? _PickerInfoCard(
                            icon: Icons.person_off_outlined,
                            title: query.length < 2
                                ? 'No popular people yet'
                                : 'No matching person found',
                            subtitle: '',
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: visibleResults.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final person = visibleResults[index];
                              final alreadySelected = _isAlreadySelected(
                                person,
                              );
                              final subtitle = [
                                person.relation.trim(),
                                person.profession.trim(),
                              ].where((part) => part.isNotEmpty).join(' · ');
                              return Material(
                                color: alreadySelected
                                    ? colorScheme.secondaryContainer
                                    : colorScheme.surfaceContainer,
                                borderRadius: BorderRadius.circular(20),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  title: Text(
                                    person.displayName,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: alreadySelected
                                          ? colorScheme.onSecondaryContainer
                                          : null,
                                    ),
                                  ),
                                  subtitle: subtitle.isEmpty
                                      ? null
                                      : Text(subtitle),
                                  trailing: Icon(
                                    alreadySelected
                                        ? Icons.check_circle_rounded
                                        : Icons.add_circle_outline_rounded,
                                    color: alreadySelected
                                        ? colorScheme.primary
                                        : null,
                                  ),
                                  onTap: alreadySelected
                                      ? null
                                      : () => Navigator.of(context).pop(person),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCreateForm(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _firstNameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'First name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _lastNameController,
          decoration: const InputDecoration(labelText: 'Last name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _relationController,
          decoration: const InputDecoration(labelText: 'Relation'),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Text(
                'Creates a saved person and returns it immediately.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            FilledButton(
              onPressed: _creating ? null : _createPerson,
              child: _creating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create'),
            ),
          ],
        ),
      ],
    );
  }
}

class _PickerInfoCard extends StatelessWidget {
  const _PickerInfoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
