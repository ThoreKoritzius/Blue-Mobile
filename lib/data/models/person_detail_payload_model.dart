import 'day_media_model.dart';
import 'person_face_model.dart';
import 'person_recognition_status_model.dart';
import 'person_model.dart';

class PersonDetailPayloadModel {
  const PersonDetailPayloadModel({
    required this.person,
    required this.faces,
    required this.images,
    required this.recognition,
    required this.imageTotalCount,
    required this.imageHasNextPage,
  });

  final PersonModel person;
  final List<PersonFaceModel> faces;
  final List<DayMediaModel> images;
  final PersonRecognitionStatusModel recognition;
  final int imageTotalCount;
  final bool imageHasNextPage;

  PersonDetailPayloadModel copyWith({
    PersonModel? person,
    List<PersonFaceModel>? faces,
    List<DayMediaModel>? images,
    PersonRecognitionStatusModel? recognition,
    int? imageTotalCount,
    bool? imageHasNextPage,
  }) {
    return PersonDetailPayloadModel(
      person: person ?? this.person,
      faces: faces ?? this.faces,
      images: images ?? this.images,
      recognition: recognition ?? this.recognition,
      imageTotalCount: imageTotalCount ?? this.imageTotalCount,
      imageHasNextPage: imageHasNextPage ?? this.imageHasNextPage,
    );
  }
}
