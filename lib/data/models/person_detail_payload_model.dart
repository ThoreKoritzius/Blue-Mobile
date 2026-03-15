import 'day_media_model.dart';
import 'person_face_model.dart';
import 'person_model.dart';

class PersonDetailPayloadModel {
  const PersonDetailPayloadModel({
    required this.person,
    required this.faces,
    required this.images,
  });

  final PersonModel person;
  final List<PersonFaceModel> faces;
  final List<DayMediaModel> images;

  PersonDetailPayloadModel copyWith({
    PersonModel? person,
    List<PersonFaceModel>? faces,
    List<DayMediaModel>? images,
  }) {
    return PersonDetailPayloadModel(
      person: person ?? this.person,
      faces: faces ?? this.faces,
      images: images ?? this.images,
    );
  }
}
