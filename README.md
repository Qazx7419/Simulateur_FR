# Тренажёр французского v1.2 — полный UI
#### Тренажер предназначен для тренировки французского произношения
#### Используйте свой список фраз, который можно изменить или пополнить через буфер обмена

UI и Auto из ABA English Trainer + нейро:

- **TTS:** Piper `fr_FR-siwis` (shim KokoroEngine)
- **ASR:** Zipformer FR (shim AsrEngine, токены = слова)
- **Сравнение:** по словам (по умолчанию)

## Запуск

```bash
flutter create . --platforms=windows
# в windows/CMakeLists.txt после project(...):
# add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
flutter pub get
flutter run -d windows
```

Модели: Documents/french_pronunciation_models_v1/
# Simulateur_FR
