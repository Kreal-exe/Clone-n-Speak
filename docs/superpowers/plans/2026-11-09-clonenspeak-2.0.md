# Clone'n'Speak 2.0 Implementation Plan (master)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clone'n'Speak 2.0: интерфейс в стиле Applio (светлая и тёмная темы, 8 палитр) и все функции Applio 1.0.8, тяжёлые — с пометкой «16 ГБ».

**Architecture:** AppKit-приложение остаётся; новая дизайн-система (`OVTheme` + `OVDesign`) заменяет стили `OVUI`, страницы регистрируются в реестре и группируются в боковой панели. Лёгкие аудио-функции — новые Python-модули рядом с `worker.py` в основном MLX-окружении. Тяжёлые (PyTorch) — отдельные окружения «движков», устанавливаемые по кнопке и запускаемые отдельными процессами через общий менеджер движков.

**Tech Stack:** Objective-C/AppKit (clang, `-Wall -Werror`, macOS 13+), Python 3 (MLX, numpy, scipy, onnxruntime), uv для окружений; pro-движки: PyTorch (MPS), бэкенд Applio (MIT), audio-separator (MIT), Seed-VC (GPL, уже есть), edge-tts, yt-dlp, cloudflared, `deep-filter`.

**Spec:** `docs/superpowers/specs/2026-11-09-clonenspeak-2.0-design.md`

Этот документ — мастер-план. Спецификация покрывает несколько независимых подсистем, поэтому этапы 2–4 начинаются
с задачи «написать подробный подплан» (`docs/superpowers/plans/2026-11-09-2.0-<подсистема>.md`) по шаблону
superpowers:writing-plans; подплан проверяет основная сессия до начала кода. Этап 1 расписан здесь полностью.

## Global Constraints

- macOS 13+, только arm64; `./build.sh` (clang `-Wall -Werror`) без ошибок и предупреждений.
- Новые `.m` подхватываются `Sources/*.m`; после добавления файлов — `python3 tools/gen_xcodeproj.py`.
- Каждая строка интерфейса — `L(@"…")` + перевод в `Resources/ru.lproj/Localizable.strings`; `python3 tools/strings.py check` проходит.
- Python-тесты: `python -m unittest discover -s tests` (рантайм-питон: `~/Library/Application Support/Clone'n'Speak/runtime/.venv/bin/python`).
- Основное окружение — без PyTorch; пиковая память основного сценария не выше цифр 1.0.3 из README.
- Код Applio/UVR/Seed-VC не копируется в репозиторий; ставится в рантайме с закреплённого коммита/версии, работает отдельным процессом.
- Pro-функции: бейдж «16 ГБ»; на Mac < 16 ГБ — предупреждение перед запуском, не запрет.
- Сетевые функции (Edge TTS, YouTube, Bridge) — согласие при первом использовании; «Офлайн-режим» в Настройках их выключает.
- Никаких градиентов, эмодзи в интерфейсе и теней у карточек; системный шрифт; системная боковая панель и title bar.
- Каждый кастомный контрол: `accessibilityRole`/`Label`/`Value`, управление с клавиатуры; анимации выключаются при Reduce Motion.
- 2.0 выходит только со всеми функциями спецификации (раздел «Без отсева»).
- Коммиты — в ветку `release/2.0`, сообщения на английском, с `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Длинная задача + переход на другую страницу/закрытие окна** — задача продолжается или корректно останавливается, UI не зависает, в «Задачах» верный статус. Тест: в подплане D, задача Jobs — «остановка процесса движка посреди работы → статус Stopped, временные файлы удалены».
2. **Pro-движок не установлен / установка прервана / нет сети** — кнопка предлагает установить, частичная установка не считается готовой, повтор продолжает. Тест: подплан C, менеджер движков — `test_engine_partial_install_is_not_ready`.
3. **8 ГБ Mac и pro-задача при загруженном OmniVoice** — OmniVoice выгружается до старта движка, предупреждение показано. Тест: подплан C — `test_pro_job_unloads_main_models_first`.
4. **Аудио на входе «неудобное»**: моно/стерео, 8–96 кГц, MP3/M4A/MP4, 0.5 с и 30 мин, тишина — все новые инструменты либо работают, либо дают внятную ошибку. Тест: подплан B — параметризованный `test_tools_accept_formats_and_lengths`.
5. **Светлая тема + каждая палитра** — текст читаем (контраст ≥ 4.5:1 для текста, ≥ 3:1 для рамок фокуса). Тест: задача 1 этого плана — `test_palette_contrast`.

---

## Этап 1. Фундамент (последовательно задачи 1→3; задача 4 параллельно)

### Task 1: Токены и палитры (`OVTheme`)

**Files:**
- Create: `Resources/themes.json`, `Sources/OVTheme.h`, `Sources/OVTheme.m`, `tests/test_themes.py`
- Modify: `Sources/OVUI.m:15-36` (старые цветовые функции становятся обёртками), `build.sh` (копировать `Resources/themes.json` в `Contents/Resources/`)

**Interfaces:**
- Produces:
  - `themes.json`: `{"palettes": [{"id": "applio", "title": "Applio", "dark": {<roles>}, "light": {<roles>}}, …]}`; роли (hex `#rrggbb` или `#rrggbbaa`): `background, surface, field, border, text, muted, accent, accentSoft, cta, ctaText, ghostBorder, log, ok, warn, err, focus`. Палитры по порядку: `applio, amethyst, crimson, cyberpunk, emerald, midnight, sunset, halloween`.
  - `Sources/OVTheme.h`:
    ```objc
    extern NSNotificationName const OVThemeDidChangeNotification;
    typedef NS_ENUM(NSInteger, OVRole) { OVRoleBackground, OVRoleSurface, OVRoleField, OVRoleBorder, OVRoleText, OVRoleMuted,
        OVRoleAccent, OVRoleAccentSoft, OVRoleCTA, OVRoleCTAText, OVRoleGhostBorder, OVRoleLog, OVRoleOK, OVRoleWarn, OVRoleErr, OVRoleFocus };
    NSColor *OVColor(OVRole role);            // dynamic: светлая/тёмная по эффективному appearance, текущая палитра
    @interface OVTheme : NSObject
    + (NSArray<NSDictionary *> *)palettes;    // @[@{@"id", @"title"}]
    + (NSString *)paletteId;                  // NSUserDefaults "OVPalette", по умолчанию "applio"
    + (void)setPaletteId:(NSString *)pid;     // сохраняет и шлёт OVThemeDidChangeNotification
    @end
    ```
  - `OVCardColor()` → `OVColor(OVRoleSurface)`, `OVWindowColor()` → `OVColor(OVRoleBackground)`, `OVAccent()` → `OVColor(OVRoleAccent)`.

- [ ] **Step 1: Write the failing test** `tests/test_themes.py`
  - `test_all_palettes_have_all_roles`: для каждой палитры и режима `dark`/`light` присутствуют все 16 ролей, hex валиден.
  - `test_palette_order`: ids == `["applio","amethyst","crimson","cyberpunk","emerald","midnight","sunset","halloween"]`.
  - `test_applio_dark_tokens`: `background #110f0f, surface #262626, field #171717, text #ffffff, muted #a3a3a3, accentSoft #404040, cta #525252, ctaText #ffffff, log #0a0a0a, ok #4ade80, warn #fbbf24, err #f87171, focus #2563eb`.
  - `test_applio_light_tokens`: `background #fafafa, surface #ffffff, field #f4f4f5, border #e4e4e7, text #09090b, muted #71717a, cta #18181b, ctaText #ffffff, focus #2563eb` (разрешено менять только ради теста контраста — тогда обновить и тест).
  - `test_palette_contrast`: WCAG-контраст `text`/`surface`, `text`/`background`, `ctaText`/`cta` ≥ 4.5; `muted`/`surface` ≥ 4.5; `focus`/`surface` ≥ 3.0 — для всех палитр в обоих режимах.
- [ ] **Step 2:** `python3 -m unittest tests.test_themes -v` → FAIL (нет файла).
- [ ] **Step 3: Write `Resources/themes.json`.** Тёмные значения остальных палитр — из `/Applications/Applio.app/Contents/Resources/app/assets/themes/<id>.json` (сопоставление ролей: `colors.background→background`, `surface→surface`, `surfaceDim→field`, `border→border`, `text→text`, `muted→muted`, `primary→accent`, `primarySoft→accentSoft`, `ctaBg→cta`, `ctaText→ctaText`; отсутствующие — как в `applio`). Светлые варианты палитр: основа светлой `applio`, `accent`/`cta` — accent палитры, затемнённый до контраста ≥ 4.5 на `surface`, `accentSoft` — accent с альфой 0x1f. Декоративные эффекты Halloween не переносить.
- [ ] **Step 4:** тест → PASS.
- [ ] **Step 5: Implement `OVTheme.m`** — грузит JSON из `NSBundle.mainBundle` один раз; `OVColor` возвращает `[NSColor colorWithName:dynamicProvider:]`, читающий текущую палитру при каждом разрешении (смена палитры не требует пересоздания цветов, только перерисовки: по уведомлению окна делают `needsDisplay`/`updateLayer` всего дерева — это в `main.m`, обработчик `OVThemeDidChangeNotification` проходит по `window.contentView` рекурсивно).
- [ ] **Step 6:** `./build.sh` → собирается; приложение открывается без визуальных регрессий, кроме смены цветов.
- [ ] **Step 7: Commit** `Add OVTheme: Applio-style tokens and 8 palettes for light and dark`.

### Task 2: Компоненты дизайн-системы (`OVDesign`) и галерея

**Files:**
- Create: `Sources/OVDesign.h`, `Sources/OVDesign.m`, `Sources/OVGalleryPage.m`
- Modify: `Sources/OVUI.m` (`OVCard` r12/рамка 1px `OVRoleBorder`/без тени/фон `OVRoleSurface`; `OVPrimaryButton` — плоская заливка `OVRoleCTA`, текст `OVRoleCTAText`, радиус 10, без градиента; `OVField` — фон `OVRoleField`, рамка 1px, радиус 10, рамка `OVRoleFocus` при фокусе; `OVSliderRow` — использует `OVSliderCell`; `OVTitle` 28/bold трекинг −0.025em, `OVSectionTitle` 18.5/bold), `Sources/OVUI.h`, `Sources/main.m` (страница `gallery` в `OVContent` и в списке `OV_SNAPSHOT_DIR`, не в боковой панели)

**Interfaces:**
- Consumes: `OVColor(OVRole)` из Task 1.
- Produces (`OVDesign.h`):
  ```objc
  NSView *OVCardHeader(NSInteger step /*0 = без номера*/, NSString *_Nullable symbol, NSString *title, NSView *_Nullable accessory);
  NSView *OVStepCard(NSInteger step, NSString *_Nullable symbol, NSString *title, NSString *_Nullable subtitle, NSView *content); // карточка с шапкой
  @interface OVDisclosure : NSView  + (instancetype)disclosureWithTitle:(NSString *)t subtitle:(nullable NSString *)s symbol:(nullable NSString *)sym content:(NSView *)c;  @property (nonatomic) BOOL expanded; @end
  @interface OVSegmented : NSControl  + (instancetype)segmentedWithItems:(NSArray<NSArray<NSString *> *> *)items; /* @[@[title, symbolOrEmpty]] */  @property (nonatomic) NSInteger selectedIndex; @end
  @interface OVSliderCell : NSSliderCell @end
  NSButton *OVGhostButton(NSString *title, NSString *_Nullable symbol, id _Nullable target, SEL _Nullable action);
  NSView *OVBadge(NSString *text, OVRole tone /*OVRoleMuted|OK|Warn|Err*/);
  NSView *OVProBadge(void);                      // «16 ГБ», тон Warn, tooltip с объяснением
  BOOL OVConfirmProRun(NSWindow *_Nullable w);   // < 16 ГБ: алерт «может не хватить памяти», YES = продолжить; ≥ 16 ГБ: YES без алерта
  @interface OVDropZone : NSView  + (instancetype)zoneWithTitle:(NSString *)t hint:(nullable NSString *)h types:(NSArray<NSString *> *)exts onFiles:(void (^)(NSArray<NSURL *> *))cb; @end
  NSView *OVEmptyState(NSString *symbol, NSString *title, NSString *_Nullable text, NSArray<NSButton *> *buttons);
  NSButton *OVPlayButton(id _Nullable target, SEL _Nullable action);   // круг 32, заливка OVRoleText, глиф OVRoleBackground
  NSScrollView *OVLogView(NSTextView *_Nullable *_Nullable outText);    // моно 12, фон OVRoleLog, радиус 8
  ```
  Размеры — из спецификации, раздел «Компоненты». `OVSegmented` — роль radio group, сегменты — radio button, ←/→ меняют выбор, шлёт action. `OVDisclosure` — анимация высоты 0.3 с, мгновенно при `NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion`.
- [ ] **Step 1:** реализовать компоненты.
- [ ] **Step 2:** `OVGalleryPage` — все компоненты в обоих состояниях (включён/выключен, выбран/нет, развёрнут/свёрнут), по карточке на компонент.
- [ ] **Step 3: Verify:** `./build.sh`, затем снимки в обеих темах:
  `OV_SNAPSHOT_DIR=/tmp/cns-snap-dark open -n "/Applications/Clone'n'Speak.app" --args -autoSetup NO -disableLegacyMigration YES -migratedFromOmniVoiceUA YES -theme dark` и то же с `light`. Ожидается: `gallery.png` в обеих папках; сверить с `docs/superpowers/specs/applio-refs/tts.png` (карточки, сегмент, слайдер) — совпадает стиль, текст читаем в обеих темах.
- [ ] **Step 4: VoiceOver/клавиатура:** в галерее Tab проходит по всем контролам, ←/→ на `OVSegmented` меняют выбор, `accessibilityRole` у `OVSegmented` = `NSAccessibilityRadioGroupRole` (проверить `-[NSView accessibilityRole]` в отладочном логе галереи при запуске с `-OVGalleryA11yDump YES`).
- [ ] **Step 5: Commit** `Add OVDesign components and a design gallery page`.

### Task 3: Реестр страниц и боковая панель с группами

**Files:**
- Create: `Sources/OVPageRegistry.h`, `Sources/OVPageRegistry.m`, `Sources/OVPlaceholderPage.m`
- Modify: `Sources/main.m` (`OVSidebar`: секции, свой `NSTableRowView`, логотип + бейдж версии, блок статуса в стиле карточки; `OVContent show:` берёт класс из реестра; `snapshotPages` — все id из реестра + `gallery`), `Sources/OVPages.h`

**Interfaces:**
- Produces:
  ```objc
  typedef struct { NSString *group, *pageId, *title, *symbol; BOOL pro; } — реализовать как NSDictionary-записи:
  @interface OVPageRegistry : NSObject
  + (NSArray<NSDictionary *> *)groups;   // @[@{@"title": L(@"VOICE"), @"pages": @[@{@"id", @"title", @"symbol", @"class", @"pro": @NO}]}]
  + (nullable Class)classForPage:(NSString *)pageId;
  @end
  ```
  Группы и id (порядок как в спецификации): VOICE — `synth` Speech `waveform`, `voices` Voices `person.wave.2`, `convert` Convert `arrow.triangle.2.circlepath` (pro), `realtime` Realtime `dot.radiowaves.left.and.right` (pro); MODELS & TRAINING — `models` Models `shippingbox`, `training` Training `graduationcap` (pro), `blender` Voice Blender `square.stack.3d.up` (pro); TOOLS — `tools` Audio Tools `slider.horizontal.3`, `separator` Separation `waveform.path.ecg`; SYSTEM — `jobs` Jobs `clock.arrow.circlepath`, `api` API & Bridge `chevron.left.forwardslash.chevron.right`, `plugins` Plugins `puzzlepiece.extension` (pro), `privacy` Data & Privacy `hand.raised`, `settings` Settings `gearshape`, `setup` Setup `checklist`. Страница `log` (Log, `text.alignleft`) в боковую панель не входит (как в Applio): остаётся в реестре как скрытая, открывается из меню Window → Log (⌥⌘L); логи задач — на странице Jobs, лог установки — в «Технических деталях» Setup. Ещё не построенные страницы → `OVPlaceholderPage` (внутренняя заглушка разработки; к релизу ни одной не остаётся — проверяется в этапе 5).
- [ ] **Step 1:** реестр + заглушка.
- [ ] **Step 2:** боковая панель: заголовки групп (11/semibold, КАПС, трекинг +0.05em, `OVRoleMuted`, не выделяются), строки 32 pt, иконка 16, выделение — свой `NSTableRowView` (плашка `OVRoleAccentSoft`, радиус 7.5, текст `OVRoleAccent`, без системного синего), бейдж `OVProBadge` у pro-страниц (компактный). `NSSplitViewItem sidebar`, title bar, кнопка темы, блок статуса и память остаются.
- [ ] **Step 3:** ⌘1…⌘9 и меню «Перейти» (если есть — `main.m:534`) строятся из реестра.
- [ ] **Step 4: Verify:** снимки обеих тем — все страницы реестра открываются (заглушки тоже), сайдбар сверить с `applio-refs/tts.png`; стрелки ↑/↓ в сайдбаре пропускают заголовки групп; VoiceOver читает «Speech, VOICE».
- [ ] **Step 5: Commit** `Group the sidebar like Applio and route pages through a registry`.

### Task 4: Спайк pro-движков на этом Mac (параллельно задачам 1–3, без кода приложения)

**Files:**
- Create: `tools/spikes/` (скрипты спайка), `docs/superpowers/notes/2026-11-09-pro-engines-spike.md`
- Окружения создавать в `~/Library/Application Support/Clone'n'Speak/engines-spike/` (удаляются после спайка).

Цель — ответить фактами, без которых нельзя писать подплан C:
- [ ] **Step 1:** публичный коммит `IAHispano/Applio` с тем же бэкендом, что в `backend/revision.json` (`59c1131…`) — существует ли; если нет — ближайший тег/коммит с рабочим `core.py`. Записать коммит и его `requirements`.
- [ ] **Step 2:** окружение uv + torch (версия из requirements Applio); RVC-инференс публичной модели (любая RVC v2 c HF с ясной лицензией) на MPS: время на 10 с аудио, пиковая память. Если MPS падает — то же на CPU.
- [ ] **Step 3:** RVC-обучение 2 эпохи на ~2 мин речи (MPS, потом CPU при сбое): время эпохи, память, рабочий ли `.pth`/`.index` на выходе.
- [ ] **Step 4:** реалтайм: задержка цепочки (чанк 0.25–0.5 с) на MPS — достижимы ли ≤ 300 мс.
- [ ] **Step 5:** совместимость torch с Seed-VC (2.8.0): может ли одно окружение обслужить Applio + Seed-VC + audio-separator; если нет — какие окружения.
- [ ] **Step 6:** audio-separator: одна вокальная модель (MDX/Roformer) на MPS — время/память; лицензия весов. Плюс ONNX-кандидат для основного уровня («удалить музыку») через onnxruntime без torch: модель, размер, лицензия, время.
- [ ] **Step 7:** `deep-filter` v0.5.6 aarch64-apple-darwin: URL, SHA-256, запуск на файле, время. edge-tts и yt-dlp: версии, работают ли.
- [ ] **Step 8:** записать в заметку таблицу «вопрос → факт → решение для подплана», удалить `engines-spike/`, commit заметки и скриптов `Record pro-engine spike results on M4 16 GB`.

---

## Этап 2. Перекраска страниц + лёгкие функции (после этапа 1; задачи параллельно в отдельных worktree)

### Task 5: Подплан A — перекраска существующих страниц
Написать `docs/superpowers/plans/2026-11-09-2.0-pages.md`, затем выполнить. По задаче на файл (параллельно, файлы не пересекаются): `OVSynthPage.m` (карточки 1 Текст / 2 Голос и стиль / 3 Результат; на виду настроение и качество, остальные слайдеры в `OVDisclosure`; эмодзи настроений → SF Symbols с `accessibilityLabel`; ✨ → `sparkles`; Recent takes — строки с `OVPlayButton`, ghost-иконками, бейджем качества), `OVVoicesPage.m` (`OVDropZone` для сэмпла, карточки голосов), `OVModelsPage.m` (вкладки `OVSegmented`, пустые состояния), `OVSettingsPage.m` (вкладки Общие/Оформление/Аудио/Хранилище/Обновления; Оформление — тема + 8 палитр с превью), `OVSetupPage.m` (шаги с номерами и бейджами, общий прогресс, `OVDisclosure` «Технические детали» с `OVLogView`), `OVTrainSheet.m`, лог-страница. Приёмка каждой: снимки обеих тем сверены с `applio-refs/`, поведение страницы не изменилось (ручной прогон её основного действия), `strings.py check`.

### Task 6: Подплан B — лёгкие аудио-функции (основной уровень)
Написать `docs/superpowers/plans/2026-11-09-2.0-audio.md`, затем выполнить. Python — новые модули рядом с `worker.py` (например `Sources/cns_fx.py`, `cns_export.py`, `cns_analyze.py`, `cns_separate.py`); `build.sh` и `OVRuntime`/`OVPaths` копируют все `Sources/*.py` в рантайм. Покрыть пункты 1–12 раздела «Функции основного уровня» спецификации: экспорт (WAV/M4A/FLAC/ALAC нативно, MP3/OGG при наличии ffmpeg), пакетная озвучка, пресеты (JSON импорт/экспорт), цепочка эффектов (reverb, delay, chorus, compressor, limiter, distortion, bitcrush, gain, EQ, pitch shift), форманты, DeepFilterNet (SHA-256 из Task 4), удаление музыки ONNX (модель из Task 4), расширенная проверка сэмпла, анализатор (данные из воркера, рисование Core Graphics), LoRA по ссылке HF, плеер со скраббером и A/B, импорт звука из видео. Страница **Аудио-инструменты** (`tools`) и лёгкая часть **Разделения** (`separator`) — здесь. TDD для каждого DSP-модуля (известный сигнал → ожидаемая характеристика), плюс тест из Review Focus №4. Приёмка: каждая функция прогнана в приложении на реальной записи.

## Этап 3. Pro-движки и новые страницы (после Task 4 и этапа 1)

### Task 7: Подплан C — pro-движки
Написать `docs/superpowers/plans/2026-11-09-2.0-pro-engines.md` по фактам Task 4, затем выполнить. Состав: менеджер движков (`OVEngines` в ObjC + единый протокол JSON-строк stdin/stdout как у `worker.py`; установка/удаление/статус/размер; тесты Review Focus №2 и №3); **Конвертация** (RVC со всеми параметрами Applio + Seed-VC клон; Single/Batch; A/B); **Реалтайм** (AVAudioEngine в приложении ↔ движок, выбор устройств, VAD, задержка ≤ 300 мс, подсказка BlackHole); **Обучение** (датасет из файлов/папки/YouTube, проверка качества датасета, preprocess/extract/train/index, детектор переобучения, продолжение, экспорт); **Смешивание** (RVC blend; OmniVoice-смешивание — экспериментально, только если звучит); RVC-модели на странице Модели (поиск, URL, импорт `.pth/.index`, информация); полное **Разделение** (audio-separator: стемы, dereverb, denoise; каталог только с ясными лицензиями весов); **Edge TTS** на странице Речь (+ прогон через RVC/Seed-VC); **YouTube-импорт** (галочка прав и согласия, один ролик, лимит длины). Каждая функция — с `OVProBadge` и `OVConfirmProRun`.

### Task 8: Подплан D — системные страницы
Написать `docs/superpowers/plans/2026-11-09-2.0-system.md`, затем выполнить: **Задачи** (история всех долгих задач приложения: озвучка, конвертация, обучение, разделение, пакеты — статус, лог, стоп, повтор; хранение в `Application Support`; тест Review Focus №1), **API** (127.0.0.1, ключ, выключен по умолчанию; эндпоинты: синтез, клон, конвертация, задачи, списки голосов/моделей), **Bridge** (`cloudflared` quick tunnel по кнопке, одобрение каждого устройства на Mac, выключен по умолчанию), **Плагины** (`plugin.json` + `main.py`, отдельный процесс в pro-окружении, выключены по умолчанию, предупреждение), **Данные и приватность**, **Офлайн-режим** и согласия на сеть.

## Этап 4. Улучшение всего приложения и безопасность

### Task 9: Сквозной аудит
Свежие агенты-ревьюеры по страницам (раздел «Улучшение всего приложения» спецификации): единые отступы, пустые состояния, тексты ошибок с действием, клавиатура/VoiceOver, Reduce Motion/Increase Contrast, долгие задачи с прогрессом и отменой, производительность списков. Находки без изменения поведения — чинить; спорное — основной сессии.

### Task 10: Security-скан
`/claude-security` → «Scan changes» на усилии `high` по ветке `release/2.0` (API, Bridge, плагины, загрузки, подпроцессы). Скан сначала называет цену — запуск только после «да» пользователя. CRITICAL/HIGH чинить; отчёт `CLAUDE-SECURITY-*/` не коммитить.

## Этап 5. Проверка и релиз

### Task 11: Приёмка на этом Mac (M4, 16 ГБ)
- [ ] `./build.sh --test` — зелёный; `tools/strings.py check` — зелёный.
- [ ] В реестре нет ни одной `OVPlaceholderPage`; `OVPlaceholderPage.m` удалён.
- [ ] Снимки всех страниц в обеих темах и трёх палитрах (`applio`, `emerald`, `midnight`) сверены с `applio-refs/`.
- [ ] Каждая функция спецификации прогнана на реальном аудио; список «функция → чем проверена → результат» — в `docs/superpowers/notes/2026-11-09-2.0-acceptance.md`.
- [ ] Пиковая память основного сценария (клон + 30 с речи) ≤ цифр 1.0.3 из README.

### Task 12: Документация и выпуск
- [ ] README (en + ru): новые функции, раздел «Для Mac с 16 ГБ», приватность и сеть; новые `docs/screenshots/` (светлая/тёмная).
- [ ] `CHANGELOG.md` — `## 2.0.0`; `Sources/Info.plist` `CFBundleShortVersionString` = `2.0.0`.
- [ ] Слить `release/2.0` в `main` и запушить → `release.yml` публикует 2.0.0. Проверить, что релиз и zip появились на GitHub.
