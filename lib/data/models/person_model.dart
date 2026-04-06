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
    this.photoPath = '',
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
  final String photoPath;

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
    String? photoPath,
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
      photoPath: photoPath ?? this.photoPath,
    );
  }

  Map<String, dynamic> toGraphqlInput() {
    return {
      'firstName': firstName,
      'lastName': lastName,
      'birthDate': birthDate,
      'deathDate': deathDate,
      'relation': relation,
      'profession': profession,
      'studyProgram': studyProgram,
      'languages': languages,
      'email': email,
      'phone': phone,
      'address': address,
      'notes': notes,
      'biography': biography,
      'photoPath': photoPath,
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'firstName': firstName,
      'lastName': lastName,
      'birthDate': birthDate,
      'deathDate': deathDate,
      'relation': relation,
      'profession': profession,
      'studyProgram': studyProgram,
      'languages': languages,
      'email': email,
      'phone': phone,
      'address': address,
      'notes': notes,
      'biography': biography,
      'photoPath': photoPath,
    };
  }

  factory PersonModel.fromJson(Map<String, dynamic> json) {
    int parseId(Object? value) {
      if (value is int) return value;
      return int.tryParse((value ?? '').toString()) ?? 0;
    }

    return PersonModel(
      id: parseId(json['id']),
      firstName: (json['firstName'] ?? json['first_name'] ?? '').toString(),
      lastName: (json['lastName'] ?? json['last_name'] ?? '').toString(),
      birthDate: (json['birthDate'] ?? json['birth_date'] ?? '').toString(),
      deathDate: (json['deathDate'] ?? json['death_date'] ?? '').toString(),
      relation: (json['relation'] ?? '').toString(),
      profession: (json['profession'] ?? '').toString(),
      studyProgram: (json['studyProgram'] ?? json['study_program'] ?? '').toString(),
      languages: (json['languages'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      phone: (json['phone'] ?? '').toString(),
      address: (json['address'] ?? '').toString(),
      notes: (json['notes'] ?? '').toString(),
      biography: (json['biography'] ?? '').toString(),
      photoPath: (json['photoPath'] ?? json['photo_path'] ?? '').toString(),
    );
  }
}
