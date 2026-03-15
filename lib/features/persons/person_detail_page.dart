import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/widgets/section_card.dart';
import '../../data/models/day_media_model.dart';
import '../../data/models/person_detail_payload_model.dart';
import '../../data/models/person_model.dart';
import '../../providers.dart';

class PersonDetailPage extends ConsumerStatefulWidget {
  const PersonDetailPage({super.key, required this.person});

  final PersonModel person;

  @override
  ConsumerState<PersonDetailPage> createState() => _PersonDetailPageState();
}

class _PersonDetailPageState extends ConsumerState<PersonDetailPage> {
  PersonDetailPayloadModel? _payload;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final payload = await ref
          .read(personRepositoryProvider)
          .loadDetail(_payload?.person ?? widget.person);
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _editPerson() async {
    final person = _payload?.person;
    if (person == null) return;

    final updated = await showModalBottomSheet<PersonModel>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => _PersonEditorSheet(person: person),
    );

    if (!mounted || updated == null) return;

    setState(() => _saving = true);
    try {
      final saved = await ref.read(personRepositoryProvider).update(updated);
      if (!mounted) return;
      setState(() {
        _payload =
            (_payload ??
                    PersonDetailPayloadModel(
                      person: saved,
                      faces: const [],
                      images: const [],
                    ))
                .copyWith(person: saved);
        _saving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Person updated.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    if (_loading && _payload == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null && _payload == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final payload = _payload!;
    final person = payload.person;
    final heroUrl = _heroUrl(payload);
    final stats = _stats(person);
    final contact = _contact(person);

    return DefaultTabController(
      length: 2,
      initialIndex: 1,
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) {
            return [
              SliverAppBar(
                pinned: true,
                expandedHeight: 248,
                backgroundColor: colorScheme.surface,
                foregroundColor: colorScheme.onSurface,
                actions: [
                  IconButton(
                    onPressed: _saving ? null : _editPerson,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.edit_outlined),
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: isDark
                            ? [
                                colorScheme.surfaceContainerHighest,
                                colorScheme.surfaceContainer,
                              ]
                            : const [Color(0xFFF6FAFF), Color(0xFFE7F0FB)],
                      ),
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 22, 20, 86),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _ProfileAvatar(
                              imageUrl: heroUrl,
                              headers: _authHeaders(),
                              fallback: _initials(person),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    person.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                          color: colorScheme.onSurface,
                                          fontWeight: FontWeight.w900,
                                        ),
                                  ),
                                  if (person.relation.trim().isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      person.relation.trim(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: colorScheme.onSurfaceVariant,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                  if (person.chips.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      height: 36,
                                      child: ListView.separated(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: person.chips.length,
                                        separatorBuilder: (_, __) =>
                                            const SizedBox(width: 8),
                                        itemBuilder: (context, index) =>
                                            _HeroBadge(
                                              label: person.chips[index],
                                            ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(64),
                  child: Container(
                    color: colorScheme.surface,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 20,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: TabBar(
                        dividerColor: Colors.transparent,
                        labelColor: colorScheme.onSurface,
                        unselectedLabelColor: colorScheme.onSurfaceVariant,
                        indicatorColor: colorScheme.primary,
                        indicatorWeight: 3,
                        tabs: const [
                          Tab(text: 'Overview'),
                          Tab(text: 'Gallery'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ];
          },
          body: TabBarView(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                children: [
                  if (stats.isNotEmpty)
                    SectionCard(
                      title: 'About',
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: stats
                            .map(
                              (stat) =>
                                  _StatCard(label: stat.$1, value: stat.$2),
                            )
                            .toList(),
                      ),
                    ),
                  if (contact.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    SectionCard(
                      title: 'Contact',
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                      child: Column(
                        children: contact
                            .map(
                              (row) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _InfoRow(label: row.$1, value: row.$2),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                  if (person.biography.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    SectionCard(
                      title: 'Story',
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                      child: Text(
                        person.biography.trim(),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurface,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              _PhotosTab(images: payload.images, headers: _authHeaders()),
            ],
          ),
        ),
      ),
    );
  }

  String _initials(PersonModel person) {
    String firstLetter(String value) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? '' : trimmed.substring(0, 1).toUpperCase();
    }

    final initials =
        '${firstLetter(person.firstName)}${firstLetter(person.lastName)}';
    return initials.isEmpty ? '?' : initials;
  }

  String? _heroUrl(PersonDetailPayloadModel payload) {
    for (final face in payload.faces) {
      if (face.isReference && face.cropPath.trim().isNotEmpty) {
        return AppConfig.faceCropUrlFromPath(face.cropPath.trim());
      }
    }
    for (final face in payload.faces) {
      if (face.cropPath.trim().isNotEmpty) {
        return AppConfig.faceCropUrlFromPath(face.cropPath.trim());
      }
    }
    for (final image in payload.images) {
      if (image.path.trim().isNotEmpty) {
        return AppConfig.imageUrlFromPath(image.path, date: image.date);
      }
    }
    return null;
  }

  List<(String, String)> _stats(PersonModel person) {
    return [
      ('Relation', person.relation.trim()),
      ('Profession', person.profession.trim()),
      ('Studies', person.studyProgram.trim()),
      ('Languages', person.languages.trim()),
      ('Born', person.birthDate.trim()),
      ('Died', person.deathDate.trim()),
    ].where((entry) => entry.$2.isNotEmpty).toList();
  }

  List<(String, String)> _contact(PersonModel person) {
    return [
      ('Email', person.email.trim()),
      ('Phone', person.phone.trim()),
      ('Address', person.address.trim()),
    ].where((entry) => entry.$2.isNotEmpty).toList();
  }

  Map<String, String> _authHeaders() {
    final tokenStore = ref.read(authTokenStoreProvider);
    final token =
        ref.read(authControllerProvider).value?.accessToken ??
        tokenStore.peekToken();
    final gatewayToken = tokenStore.peekGatewayToken();
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (gatewayToken != null && gatewayToken.isNotEmpty)
        'X-Gateway-Session': gatewayToken,
    };
  }
}

class _PhotosTab extends StatelessWidget {
  const _PhotosTab({required this.images, required this.headers});

  final List<DayMediaModel> images;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: const [
          SectionCard(
            title: 'Photos',
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('No photos linked to this person yet.'),
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1100
            ? 4
            : width >= 760
            ? 3
            : 2;
        final aspectRatio = width >= 760 ? 0.96 : 0.86;

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: aspectRatio,
          ),
          itemCount: images.length,
          itemBuilder: (context, index) {
            final image = images[index];
            final imageUrl = AppConfig.imageUrlFromPath(
              image.path,
              date: image.date,
            );
            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => showDialog<void>(
                  context: context,
                  barrierColor: Colors.black.withValues(alpha: 0.9),
                  builder: (_) => _GalleryImageDialog(
                    imageUrl: imageUrl,
                    headers: headers,
                    title: image.fileName,
                    subtitle: image.date,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: imageUrl,
                        httpHeaders: headers,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.image_not_supported_outlined,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.02),
                              Colors.black.withValues(alpha: 0.08),
                              Colors.black.withValues(alpha: 0.44),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                image.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                image.date,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _GalleryImageDialog extends StatelessWidget {
  const _GalleryImageDialog({
    required this.imageUrl,
    required this.headers,
    required this.title,
    required this.subtitle,
  });

  final String imageUrl;
  final Map<String, String> headers;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.7,
              maxScale: 4,
              child: Center(
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  httpHeaders: headers,
                  fit: BoxFit.contain,
                  errorWidget: (_, __, ___) => const Icon(
                    Icons.image_not_supported_outlined,
                    color: Colors.white70,
                    size: 40,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 18,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonEditorSheet extends StatefulWidget {
  const _PersonEditorSheet({required this.person});

  final PersonModel person;

  @override
  State<_PersonEditorSheet> createState() => _PersonEditorSheetState();
}

class _PersonEditorSheetState extends State<_PersonEditorSheet> {
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _relation;
  late final TextEditingController _profession;
  late final TextEditingController _birthDate;
  late final TextEditingController _deathDate;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _languages;
  late final TextEditingController _studyProgram;
  late final TextEditingController _biography;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    final person = widget.person;
    _firstName = TextEditingController(text: person.firstName);
    _lastName = TextEditingController(text: person.lastName);
    _relation = TextEditingController(text: person.relation);
    _profession = TextEditingController(text: person.profession);
    _birthDate = TextEditingController(text: person.birthDate);
    _deathDate = TextEditingController(text: person.deathDate);
    _email = TextEditingController(text: person.email);
    _phone = TextEditingController(text: person.phone);
    _address = TextEditingController(text: person.address);
    _languages = TextEditingController(text: person.languages);
    _studyProgram = TextEditingController(text: person.studyProgram);
    _biography = TextEditingController(text: person.biography);
    _notes = TextEditingController(text: person.notes);
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _relation.dispose();
    _profession.dispose();
    _birthDate.dispose();
    _deathDate.dispose();
    _email.dispose();
    _phone.dispose();
    _address.dispose();
    _languages.dispose();
    _studyProgram.dispose();
    _biography.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 18, 18, 24 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit person',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 18),
            _FormRow(
              children: [
                _EditorField(controller: _firstName, label: 'First name'),
                _EditorField(controller: _lastName, label: 'Last name'),
              ],
            ),
            _FormRow(
              children: [
                _EditorField(controller: _relation, label: 'Relation'),
                _EditorField(controller: _profession, label: 'Occupation'),
              ],
            ),
            _FormRow(
              children: [
                _EditorField(controller: _birthDate, label: 'Birth date'),
                _EditorField(controller: _deathDate, label: 'Death date'),
              ],
            ),
            _FormRow(
              children: [
                _EditorField(controller: _email, label: 'Email'),
                _EditorField(controller: _phone, label: 'Phone'),
              ],
            ),
            _EditorField(controller: _address, label: 'Address'),
            const SizedBox(height: 12),
            _FormRow(
              children: [
                _EditorField(controller: _languages, label: 'Languages'),
                _EditorField(controller: _studyProgram, label: 'Studies'),
              ],
            ),
            _EditorField(
              controller: _biography,
              label: 'Biography',
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            _EditorField(
              controller: _notes,
              label: 'Important notes',
              maxLines: 3,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        widget.person.copyWith(
                          firstName: _firstName.text.trim(),
                          lastName: _lastName.text.trim(),
                          relation: _relation.text.trim(),
                          profession: _profession.text.trim(),
                          birthDate: _birthDate.text.trim(),
                          deathDate: _deathDate.text.trim(),
                          email: _email.text.trim(),
                          phone: _phone.text.trim(),
                          address: _address.text.trim(),
                          languages: _languages.text.trim(),
                          studyProgram: _studyProgram.text.trim(),
                          biography: _biography.text.trim(),
                          notes: _notes.text.trim(),
                        ),
                      );
                    },
                    child: const Text('Save changes'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FormRow extends StatelessWidget {
  const _FormRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.sizeOf(context).width < 620;
    if (isNarrow) {
      return Column(
        children:
            children
                .expand((child) => [child, const SizedBox(height: 12)])
                .toList()
              ..removeLast(),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(child: children.first),
          const SizedBox(width: 12),
          Expanded(child: children.last),
        ],
      ),
    );
  }
}

class _EditorField extends StatelessWidget {
  const _EditorField({
    required this.controller,
    required this.label,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      decoration: InputDecoration(labelText: label),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.imageUrl,
    required this.headers,
    required this.fallback,
  });

  final String? imageUrl;
  final Map<String, String> headers;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 116,
      height: 116,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.surfaceContainerHighest,
        border: Border.all(color: colorScheme.surface, width: 4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl == null || imageUrl!.isEmpty
          ? _AvatarFallback(text: fallback)
          : CachedNetworkImage(
              imageUrl: imageUrl!,
              httpHeaders: headers,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _AvatarFallback(text: fallback),
            ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF174EA6),
      child: Center(
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 36,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _HeroBadge extends StatelessWidget {
  const _HeroBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.46;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth.clamp(120.0, 220.0)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colorScheme.onSecondaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 154,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
