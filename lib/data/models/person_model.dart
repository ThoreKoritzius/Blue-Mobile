class PersonModel {
  const PersonModel({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.birthDate,
    required this.deathDate,
    required this.relation,
    required this.profession,
    required this.studyProgram,
    required this.languages,
    required this.email,
    required this.phone,
    required this.address,
    required this.notes,
    required this.biography,
  });

  final int id;
  final String firstName;
  final String lastName;
  final String birthDate;
  final String deathDate;
  final String relation;
  final String profession;
  final String studyProgram;
  final String languages;
  final String email;
  final String phone;
  final String address;
  final String notes;
  final String biography;

  String get displayName {
    final parts = [
      firstName.trim(),
      lastName.trim(),
    ].where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? 'Unknown person' : parts.join(' ');
  }

  List<String> get chips => [
    relation.trim(),
    profession.trim(),
    studyProgram.trim(),
  ].where((item) => item.isNotEmpty).toList();

  PersonModel copyWith({
    int? id,
    String? firstName,
    String? lastName,
    String? birthDate,
    String? deathDate,
    String? relation,
    String? profession,
    String? studyProgram,
    String? languages,
    String? email,
    String? phone,
    String? address,
    String? notes,
    String? biography,
  }) {
    return PersonModel(
      id: id ?? this.id,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      birthDate: birthDate ?? this.birthDate,
      deathDate: deathDate ?? this.deathDate,
      relation: relation ?? this.relation,
      profession: profession ?? this.profession,
      studyProgram: studyProgram ?? this.studyProgram,
      languages: languages ?? this.languages,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      address: address ?? this.address,
      notes: notes ?? this.notes,
      biography: biography ?? this.biography,
    );
  }

  Map<String, dynamic> toGraphqlInput() {
    return {
      'vorname': firstName,
      'nachname': lastName,
      'geburtsdatum': birthDate,
      'todesdatum': deathDate,
      'relation': relation,
      'beruf': profession,
      'studiengang': studyProgram,
      'sprachen': languages,
      'mail': email,
      'telefon': phone,
      'adresse': address,
      'wichtiges': notes,
      'lebenslauf': biography,
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'vorname': firstName,
      'nachname': lastName,
      'geburtsdatum': birthDate,
      'todesdatum': deathDate,
      'relation': relation,
      'beruf': profession,
      'studiengang': studyProgram,
      'sprachen': languages,
      'mail': email,
      'telefon': phone,
      'adresse': address,
      'wichtiges': notes,
      'lebenslauf': biography,
    };
  }

  factory PersonModel.fromJson(Map<String, dynamic> json) {
    int parseId(Object? value) {
      if (value is int) return value;
      return int.tryParse((value ?? '').toString()) ?? 0;
    }

    return PersonModel(
      id: parseId(json['id']),
      firstName: (json['vorname'] ?? json['first_name'] ?? '').toString(),
      lastName: (json['nachname'] ?? json['last_name'] ?? '').toString(),
      birthDate: (json['geburtsdatum'] ?? '').toString(),
      deathDate: (json['todesdatum'] ?? '').toString(),
      relation: (json['relation'] ?? '').toString(),
      profession: (json['beruf'] ?? '').toString(),
      studyProgram: (json['studiengang'] ?? '').toString(),
      languages: (json['sprachen'] ?? '').toString(),
      email: (json['mail'] ?? '').toString(),
      phone: (json['telefon'] ?? '').toString(),
      address: (json['adresse'] ?? '').toString(),
      notes: (json['wichtiges'] ?? '').toString(),
      biography: (json['lebenslauf'] ?? '').toString(),
    );
  }
}
