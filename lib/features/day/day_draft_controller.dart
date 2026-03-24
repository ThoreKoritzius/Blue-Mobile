import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DayDraftStatus { clean, dirty, saving, saveError }

class DayDraftState {
  const DayDraftState({
    required this.status,
    required this.statusText,
    required this.currentDay,
    required this.uploading,
    required this.savedAt,
    required this.errorMessage,
  });

  final DayDraftStatus status;
  final String statusText;
  final String? currentDay;
  final bool uploading;
  final DateTime? savedAt;
  final String? errorMessage;

  bool get canNavigate => status == DayDraftStatus.clean && !uploading;
  bool get isDirty => status == DayDraftStatus.dirty;
  bool get isSaving => status == DayDraftStatus.saving;
  bool get hasError => status == DayDraftStatus.saveError;

  DayDraftState copyWith({
    DayDraftStatus? status,
    String? statusText,
    String? currentDay,
    bool? uploading,
    DateTime? savedAt,
    bool clearSavedAt = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return DayDraftState(
      status: status ?? this.status,
      statusText: statusText ?? this.statusText,
      currentDay: currentDay ?? this.currentDay,
      uploading: uploading ?? this.uploading,
      savedAt: clearSavedAt ? null : (savedAt ?? this.savedAt),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  static const initial = DayDraftState(
    status: DayDraftStatus.clean,
    statusText: '',
    currentDay: null,
    uploading: false,
    savedAt: null,
    errorMessage: null,
  );
}

class DayDraftController extends Notifier<DayDraftState> {
  @override
  DayDraftState build() => DayDraftState.initial;

  void setCurrentDay(String day) {
    state = state.copyWith(currentDay: day);
  }

  void markClean({DateTime? savedAt, String? text}) {
    state = state.copyWith(
      status: DayDraftStatus.clean,
      statusText: text ?? '',
      savedAt: savedAt,
      clearError: true,
    );
  }

  void markDirty({String text = 'Unsaved changes'}) {
    state = state.copyWith(
      status: DayDraftStatus.dirty,
      statusText: text,
      clearSavedAt: true,
      clearError: true,
    );
  }

  void markSaving({String text = 'Saving'}) {
    state = state.copyWith(
      status: DayDraftStatus.saving,
      statusText: text,
      clearError: true,
    );
  }

  void markError(String message, {String text = 'Retry needed'}) {
    state = state.copyWith(
      status: DayDraftStatus.saveError,
      statusText: text,
      errorMessage: message,
      clearSavedAt: true,
    );
  }

  void setUploading(bool uploading, {String? text}) {
    state = state.copyWith(
      uploading: uploading,
      statusText: text ?? state.statusText,
    );
  }

  void setStatusText(String text) {
    state = state.copyWith(statusText: text);
  }
}
